//! ICMP echo through the IP Helper API, which Windows grants without
//! administrator rights where it denies ICMP sockets.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const windows = std.os.windows;
const HANDLE = windows.HANDLE;

const icmp = @import("icmp.zig");
const probe = @import("probe.zig");

const payload = "libspeed";
const AF_INET6 = 23;
const IP_SUCCESS = 0;
const INFINITE = 0xffffffff;

/// Room for a reply, its payload, an ICMP error and the IO_STATUS_BLOCK an
/// asynchronous echo appends.
const Reply = [128]u8;

const Sockaddr6 = extern struct {
    family: u16 = AF_INET6,
    port: u16 = 0,
    flowinfo: u32 = 0,
    addr: [16]u8 = @splat(0),
    scope_id: u32 = 0,
};

extern "iphlpapi" fn IcmpCreateFile() callconv(.winapi) HANDLE;
extern "iphlpapi" fn Icmp6CreateFile() callconv(.winapi) HANDLE;
extern "iphlpapi" fn IcmpCloseHandle(handle: HANDLE) callconv(.winapi) c_int;
extern "iphlpapi" fn IcmpSendEcho2(handle: HANDLE, event: ?HANDLE, apc: ?*anyopaque, apc_context: ?*anyopaque, destination: u32, data: *const anyopaque, size: u16, options: ?*anyopaque, reply: *Reply, reply_size: u32, timeout: u32) callconv(.winapi) u32;
extern "iphlpapi" fn Icmp6SendEcho2(handle: HANDLE, event: ?HANDLE, apc: ?*anyopaque, apc_context: ?*anyopaque, source: *const Sockaddr6, destination: *const Sockaddr6, data: *const anyopaque, size: u16, options: ?*anyopaque, reply: *Reply, reply_size: u32, timeout: u32) callconv(.winapi) u32;
extern "iphlpapi" fn IcmpParseReplies(reply: *Reply, size: u32) callconv(.winapi) u32;
extern "iphlpapi" fn Icmp6ParseReplies(reply: *Reply, size: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: c_int, initial_state: c_int, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;

const Pinger = struct {
    handle: HANDLE,
    target: net.IpAddress,

    fn open(target: net.IpAddress) !Pinger {
        const handle = if (target == .ip6) Icmp6CreateFile() else IcmpCreateFile();
        if (handle == windows.INVALID_HANDLE_VALUE) return error.IcmpUnavailable;
        return .{ .handle = handle, .target = target };
    }

    fn close(p: Pinger) void {
        _ = IcmpCloseHandle(p.handle);
    }

    /// Without `event`, blocks until the reply or `timeout` and returns the
    /// number of replies. With it, returns 0 at once and signals `event` once
    /// `reply` is written.
    fn send(p: Pinger, event: ?HANDLE, reply: *Reply, timeout: Io.Duration) u32 {
        const ms: u32 = @intCast(std.math.clamp(timeout.toMilliseconds(), 1, INFINITE - 1));
        return switch (p.target) {
            .ip4 => |a| IcmpSendEcho2(p.handle, event, null, null, @bitCast(a.bytes), payload, payload.len, null, reply, reply.len, ms),
            .ip6 => |a| Icmp6SendEcho2(p.handle, event, null, null, &.{}, &.{
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            }, payload, payload.len, null, reply, reply.len, ms),
        };
    }

    /// Whether a completed asynchronous echo got a reply.
    fn parse(p: Pinger, reply: *Reply) bool {
        const n = if (p.target == .ip6) Icmp6ParseReplies(reply, reply.len) else IcmpParseReplies(reply, reply.len);
        return n > 0 and p.succeeded(reply);
    }

    /// Whether the first reply is an echo reply, not an ICMP error.
    fn succeeded(p: Pinger, reply: *const Reply) bool {
        const status_offset: usize = if (p.target == .ip6) 28 else 4;
        return std.mem.readInt(u32, reply[status_offset..][0..4], .native) == IP_SUCCESS;
    }
};

/// Same contract as `icmp.loss`.
pub fn loss(io: Io, target: net.IpAddress, options: icmp.Options) !f64 {
    const pinger: Pinger = try .open(target);
    defer pinger.close();

    var replies: [256]Reply align(8) = undefined;
    var events: [256]HANDLE = undefined;
    var pending: usize = 0;
    // A pending echo writes into its reply until it signals its event, at the
    // latest after its timeout.
    defer for (events[0..pending]) |event| {
        _ = WaitForSingleObject(event, INFINITE);
        windows.CloseHandle(event);
    };

    const start = Io.Clock.awake.now(io);
    for (0..options.count) |i| {
        const event = CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        if (pinger.send(event, &replies[i], options.timeout) != 0 or windows.GetLastError() != .IO_PENDING) {
            windows.CloseHandle(event);
            return error.IcmpSendFailed;
        }
        events[i] = event;
        pending += 1;
        const next = start.addDuration(.fromNanoseconds(options.interval.toNanoseconds() * @as(i96, @intCast(i + 1))));
        try (Io.Timeout{ .deadline = .{ .raw = next, .clock = .awake } }).sleep(io);
    }

    var received: usize = 0;
    for (events[0..pending], replies[0..pending]) |event, *reply| {
        _ = WaitForSingleObject(event, INFINITE);
        if (pinger.parse(reply)) received += 1;
    }
    if (received == 0) return error.NoReplies;
    return 1 - @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(options.count));
}

/// Same contract as `icmp.Echo`.
pub const Echo = struct {
    pinger: Pinger,
    timeout: Io.Duration = .fromMilliseconds(1000),

    pub fn open(io: Io, target: net.IpAddress) !Echo {
        _ = io;
        return .{ .pinger = try .open(target) };
    }

    pub fn close(e: *Echo, io: Io) void {
        _ = io;
        e.pinger.close();
    }

    // ponytail: blocks its thread until the reply, so cancelling waits up to
    // `timeout` for a silent host; send with an event if phase ends drag.
    pub fn ms(e: *Echo, io: Io) !f64 {
        var reply: Reply align(8) = undefined;
        const start = Io.Clock.awake.now(io);
        const replies = e.pinger.send(null, &reply, e.timeout);
        const elapsed = start.untilNow(io, .awake);
        if (replies == 0 or !e.pinger.succeeded(&reply)) return error.Timeout;
        return probe.ms(elapsed);
    }
};
