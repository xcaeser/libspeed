//! Finds the IPv4 default gateway, the router every packet to the internet
//! crosses first, and whether this device reaches it over Wi-Fi.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

pub const Gateway = struct {
    address: net.IpAddress,
    wireless: bool,
};

/// Returns null when there is no IPv4 default route or the routing table
/// can't be read.
// ponytail: IPv4 only; an IPv6-only network has no verdict. Add the v6 default
// route (link-local, needs a scope id) if such networks show up.
pub fn find(io: Io, gpa: Allocator) !?Gateway {
    return switch (builtin.os.tag) {
        .macos => darwin.find(gpa) catch |err| switch (err) {
            error.OutOfMemory => |e| e,
            error.Sysctl => null,
        },
        .linux => linux.find(io) catch |err| switch (err) {
            error.Canceled => |e| e,
            else => null,
        },
        .windows => windows.find(),
        else => null,
    };
}

fn ip4(bytes: [4]u8) net.IpAddress {
    return .{ .ip4 = .{ .bytes = bytes, .port = 0 } };
}

const darwin = struct {
    const c = std.c;
    const RTF_GATEWAY = 0x2;
    /// Per-interface copies of the default route; the unscoped one is primary.
    const RTF_IFSCOPE = 0x1000000;
    const NET_RT_FLAGS = 2;
    const rt_msghdr_len = 92;
    const SIOCGIFFUNCTIONALTYPE: u32 = 0xc02069ad;
    const IFRTYPE_FUNCTIONAL_WIFI_INFRA = 3;

    extern "c" fn if_indextoname(index: c_uint, name: *[16]u8) ?[*:0]u8;

    fn find(gpa: Allocator) !?Gateway {
        var mib = [_]c_int{ c.CTL.NET, c.AF.ROUTE, 0, c.AF.INET, NET_RT_FLAGS, RTF_GATEWAY };
        var len: usize = 0;
        if (c.sysctl(&mib, mib.len, null, &len, null, 0) != 0) return error.Sysctl;
        // Room for routes added between the two calls.
        len += len / 2;
        const table = try gpa.alloc(u8, len);
        defer gpa.free(table);
        if (c.sysctl(&mib, mib.len, table.ptr, &len, null, 0) != 0) return error.Sysctl;
        const route = defaultRoute(table[0..len]) orelse return null;
        return .{ .address = ip4(route.gateway), .wireless = wireless(route.index) };
    }

    const Route = struct { gateway: [4]u8, index: u16 };

    /// Walks routing messages, each a header followed by the sockaddrs its
    /// `rtm_addrs` bits name, in bit order, each padded to 4 bytes.
    fn defaultRoute(table: []const u8) ?Route {
        var rest = table;
        while (rest.len >= rt_msghdr_len) {
            const len = std.mem.readInt(u16, rest[0..2], .native);
            if (len < rt_msghdr_len or len > rest.len) return null;
            const msg = rest[0..len];
            rest = rest[len..];
            const flags = std.mem.readInt(i32, msg[8..12], .native);
            const addrs = std.mem.readInt(i32, msg[12..16], .native);
            if (flags & RTF_IFSCOPE != 0) continue;

            var sockaddrs: [3]?[]const u8 = @splat(null); // dst, gateway, netmask
            var sa = msg[rt_msghdr_len..];
            for (0..8) |bit| {
                if (addrs & (@as(i32, 1) << @intCast(bit)) == 0) continue;
                if (sa.len == 0) break;
                const sa_len: usize = sa[0];
                if (bit < sockaddrs.len) sockaddrs[bit] = sa[0..@min(sa_len, sa.len)];
                sa = sa[@min(if (sa_len == 0) 4 else std.mem.alignForward(usize, sa_len, 4), sa.len)..];
            }
            const dst = sockaddrs[0] orelse continue;
            const gateway = sockaddrs[1] orelse continue;
            if (!isIn4(dst) or !std.mem.allEqual(u8, dst[4..8], 0)) continue;
            if (!isIn4(gateway)) continue;
            // 0.0.0.0/1 and 128.0.0.0/1 are a VPN's split default, not the router.
            if (sockaddrs[2]) |mask| if (mask.len > 4 and !std.mem.allEqual(u8, mask[4..], 0)) continue;
            return .{ .gateway = gateway[4..8].*, .index = std.mem.readInt(u16, msg[4..6], .native) };
        }
        return null;
    }

    /// A sockaddr_in: length, family, port, then the address.
    fn isIn4(sa: []const u8) bool {
        return sa.len >= 8 and sa[1] == c.AF.INET;
    }

    fn wireless(index: u16) bool {
        var ifr: [32]u8 = @splat(0);
        if (if_indextoname(index, ifr[0..16]) == null) return false;
        const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        if (c.ioctl(fd, @bitCast(SIOCGIFFUNCTIONALTYPE), &ifr) != 0) return false;
        return std.mem.readInt(u32, ifr[16..20], .native) == IFRTYPE_FUNCTIONAL_WIFI_INFRA;
    }
};

const linux = struct {
    fn find(io: Io) !?Gateway {
        var buf: [16 << 10]u8 = undefined;
        const table = try Io.Dir.cwd().readFile(io, "/proc/net/route", &buf);
        const route = defaultRoute(table) orelse return null;
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/wireless", .{route.iface});
        const wireless = if (Io.Dir.cwd().access(io, path, .{})) true else |_| false;
        return .{ .address = ip4(route.gateway), .wireless = wireless };
    }

    const Route = struct { gateway: [4]u8, iface: []const u8 };

    /// The lowest-metric default route in /proc/net/route, whose addresses are
    /// the hex of the address bytes read as a native integer.
    fn defaultRoute(table: []const u8) ?Route {
        var best: ?Route = null;
        var best_metric: u32 = std.math.maxInt(u32);
        var lines = std.mem.tokenizeScalar(u8, table, '\n');
        _ = lines.next(); // column names
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const iface = fields.next() orelse continue;
            const dst = fields.next() orelse continue;
            const gateway = fields.next() orelse continue;
            const flags = fields.next() orelse continue;
            _ = fields.next(); // RefCnt
            _ = fields.next(); // Use
            const metric = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            const RTF_UP = 0x1;
            const RTF_GATEWAY = 0x2;
            const f = std.fmt.parseInt(u16, flags, 16) catch continue;
            if (f & (RTF_UP | RTF_GATEWAY) != RTF_UP | RTF_GATEWAY) continue;
            if ((std.fmt.parseInt(u32, dst, 16) catch continue) != 0) continue;
            const address = std.fmt.parseInt(u32, gateway, 16) catch continue;
            if (metric >= best_metric) continue;
            best = .{ .gateway = std.mem.toBytes(address), .iface = iface };
            best_metric = metric;
        }
        return best;
    }

    test defaultRoute {
        const table =
            "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" ++
            "eth0\t00000000\t0100000A\t0003\t0\t0\t600\t00000000\t0\t0\t0\n" ++
            "wlan0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n" ++
            "wlan0\t0001A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n";
        const route = defaultRoute(table).?;
        try std.testing.expectEqualStrings("wlan0", route.iface);
        // The fixture is written as a little-endian kernel prints it.
        if (builtin.cpu.arch.endian() == .little) try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, route.gateway);
        try std.testing.expectEqual(null, defaultRoute(table[0..std.mem.indexOfScalar(u8, table, '\n').?]));
    }
};

const windows = struct {
    const AF_INET = 2;
    const IF_TYPE_IEEE80211 = 71;

    /// SOCKADDR_INET, read as its IPv4 member.
    const Sockaddr = extern struct {
        family: u16,
        port: u16 = 0,
        addr: [4]u8,
        unused: [5]u32 = @splat(0),
    };

    /// MIB_IPFORWARD_ROW2, up to the fields read here.
    const Row = extern struct {
        luid: u64,
        index: u32,
        destination: Sockaddr,
        prefix_length: u8,
        next_hop: Sockaddr,
        unused: [8]u32,
    };

    comptime {
        std.debug.assert(@sizeOf(Row) == 104);
        std.debug.assert(@offsetOf(Row, "next_hop") == 44);
    }

    extern "iphlpapi" fn GetBestRoute2(
        luid: ?*const u64,
        index: u32,
        source: ?*const Sockaddr,
        destination: *const Sockaddr,
        sort_options: u32,
        route: *Row,
        best_source: *Sockaddr,
    ) callconv(.winapi) u32;

    fn find() ?Gateway {
        // Any public address takes the default route.
        const destination: Sockaddr = .{ .family = AF_INET, .addr = .{ 1, 1, 1, 1 } };
        var route: Row = undefined;
        var source: Sockaddr = undefined;
        if (GetBestRoute2(null, 0, null, &destination, 0, &route, &source) != 0) return null;
        return fromRow(route);
    }

    fn fromRow(route: Row) ?Gateway {
        // A VPN's split default (0.0.0.0/1, 128.0.0.0/1) or an on-link route
        // leaves no router to time.
        if (route.prefix_length != 0 or route.next_hop.family != AF_INET) return null;
        if (std.mem.allEqual(u8, &route.next_hop.addr, 0)) return null;
        // A LUID's top 16 bits are its interface type.
        return .{ .address = ip4(route.next_hop.addr), .wireless = route.luid >> 48 == IF_TYPE_IEEE80211 };
    }

    test fromRow {
        var route: Row = .{
            .luid = @as(u64, IF_TYPE_IEEE80211) << 48 | 1 << 24,
            .index = 12,
            .destination = .{ .family = AF_INET, .addr = @splat(0) },
            .prefix_length = 0,
            .next_hop = .{ .family = AF_INET, .addr = .{ 192, 168, 1, 1 } },
            .unused = @splat(0),
        };
        const gateway = fromRow(route).?;
        try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, gateway.address.ip4.bytes);
        try std.testing.expect(gateway.wireless);

        route.luid = 6 << 48; // Ethernet
        try std.testing.expect(!fromRow(route).?.wireless);
        route.prefix_length = 1;
        try std.testing.expectEqual(null, fromRow(route));
        route.prefix_length = 0;
        route.next_hop.addr = @splat(0);
        try std.testing.expectEqual(null, fromRow(route));
    }
};

test {
    _ = linux;
    _ = windows;
}
