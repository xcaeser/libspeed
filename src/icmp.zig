//! Packet loss over unprivileged ICMP echo (SOCK_DGRAM + IPPROTO_ICMP).
//! Works without root on macOS, and on Linux when `net.ipv4.ping_group_range`
//! includes the user. Windows goes through the IP Helper API instead.
//! Elsewhere `loss` fails and the caller reports it as unknown.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;

const probe = @import("probe.zig");
const windows = @import("icmp_windows.zig");

const header_len = 8;
const token_len = 8;

pub const Options = struct {
    count: u8 = 50,
    interval: Io.Duration = .fromMilliseconds(20),
    timeout: Io.Duration = .fromMilliseconds(1000),
};

/// Returns the fraction of echo requests that got no reply in [0, 1], after
/// `count * interval + timeout`. Fails when no reply arrives at all, since a
/// firewall dropping ICMP says nothing about the link.
pub fn loss(io: Io, target: net.IpAddress, options: Options) !f64 {
    if (builtin.os.tag == .windows) return windows.loss(io, target, options);
    const v6 = target == .ip6;
    const socket = try bind(io, v6);
    defer socket.close(io);

    var token: [token_len]u8 = undefined;
    io.random(&token);

    var replied: std.StaticBitSet(256) = .empty;
    const start = Io.Clock.awake.now(io);
    for (0..options.count) |i| {
        const seq: u8 = @intCast(i);
        const request = echoRequest(v6, seq, token);
        try socket.send(io, &target, &request);
        const next = start.addDuration(.fromNanoseconds(options.interval.toNanoseconds() * @as(i96, @intCast(i + 1))));
        const until = if (i + 1 == options.count) next.addDuration(options.timeout) else next;
        try collect(io, socket, v6, token, until, &replied);
    }

    const received = replied.count();
    if (received == 0) return error.NoReplies;
    return 1 - @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(options.count));
}

/// Times echoes to one host, one at a time.
pub const Echo = if (builtin.os.tag == .windows) windows.Echo else SocketEcho;

const SocketEcho = struct {
    socket: net.Socket,
    target: net.IpAddress,
    token: [token_len]u8,
    seq: u8 = 0,
    timeout: Io.Duration = .fromMilliseconds(1000),

    pub fn open(io: Io, target: net.IpAddress) !SocketEcho {
        var token: [token_len]u8 = undefined;
        io.random(&token);
        return .{ .socket = try bind(io, target == .ip6), .target = target, .token = token };
    }

    pub fn close(e: *SocketEcho, io: Io) void {
        e.socket.close(io);
    }

    /// Round trip of one echo in ms, or error.Timeout when no reply arrives
    /// in time. Late replies to earlier echoes are ignored.
    pub fn ms(e: *SocketEcho, io: Io) !f64 {
        const v6 = e.target == .ip6;
        e.seq +%= 1;
        const request = echoRequest(v6, e.seq, e.token);
        const start = Io.Clock.awake.now(io);
        try e.socket.send(io, &e.target, &request);
        const deadline: Io.Timeout = .{ .deadline = .{ .raw = start.addDuration(e.timeout), .clock = .awake } };
        var buf: [1500]u8 = undefined;
        while (true) {
            const message = try e.socket.receiveTimeout(io, &buf, deadline);
            if (replySeq(message.data, v6, e.token) == e.seq) return probe.ms(start.untilNow(io, .awake));
        }
    }
};

fn bind(io: Io, v6: bool) !net.Socket {
    const local: net.IpAddress = if (v6) .{ .ip6 = .unspecified(0) } else .{ .ip4 = .unspecified(0) };
    return local.bind(io, .{ .mode = .dgram, .protocol = if (v6) .icmpv6 else .icmp });
}

/// Records replies until `until`.
fn collect(io: Io, socket: net.Socket, v6: bool, token: [token_len]u8, until: Io.Timestamp, replied: *std.StaticBitSet(256)) !void {
    var buf: [1500]u8 = undefined;
    while (true) {
        const message = socket.receiveTimeout(io, &buf, .{ .deadline = .{ .raw = until, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => return,
            else => |e| return e,
        };
        if (replySeq(message.data, v6, token)) |seq| replied.set(seq);
    }
}

fn echoRequest(v6: bool, seq: u8, token: [token_len]u8) [header_len + token_len]u8 {
    var p: [header_len + token_len]u8 = undefined;
    p[0] = if (v6) 128 else 8;
    p[1] = 0;
    std.mem.writeInt(u16, p[2..4], 0, .big);
    // The kernel rewrites the identifier on Linux, so replies are matched by seq and token.
    std.mem.writeInt(u16, p[4..6], 0, .big);
    std.mem.writeInt(u16, p[6..8], seq, .big);
    p[header_len..].* = token;
    // ICMPv6 checksums cover a pseudo-header the kernel fills in.
    if (!v6) std.mem.writeInt(u16, p[2..4], checksum(&p), .big);
    return p;
}

/// Returns the sequence number of our echo reply, or null for other traffic.
fn replySeq(data: []const u8, v6: bool, token: [token_len]u8) ?u8 {
    var icmp = data;
    // macOS delivers IPv4 replies with their IP header attached.
    if (!v6 and icmp.len > 0 and icmp[0] >> 4 == 4) {
        const ihl = @as(usize, icmp[0] & 0x0f) * 4;
        if (icmp.len < ihl) return null;
        icmp = icmp[ihl..];
    }
    if (icmp.len < header_len + token_len) return null;
    if (icmp[0] != @as(u8, if (v6) 129 else 0)) return null;
    if (!std.mem.eql(u8, icmp[header_len..][0..token_len], &token)) return null;
    return std.math.cast(u8, std.mem.readInt(u16, icmp[6..8], .big));
}

fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) sum += std.mem.readInt(u16, bytes[i..][0..2], .big);
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

test "echo request checksums to zero" {
    const p = echoRequest(false, 7, "abcdefgh".*);
    try std.testing.expectEqual(@as(u16, 0), checksum(&p));
}

test "reply matching" {
    const token = "abcdefgh".*;
    var reply = echoRequest(false, 3, token);
    reply[0] = 0;
    try std.testing.expectEqual(3, replySeq(&reply, false, token));
    try std.testing.expectEqual(null, replySeq(&reply, false, "zzzzzzzz".*));
    var request = echoRequest(false, 3, token);
    try std.testing.expectEqual(null, replySeq(&request, false, token));

    // Same reply behind a 20-byte IPv4 header, as macOS delivers it.
    var framed: [20 + reply.len]u8 = @splat(0);
    framed[0] = 0x45;
    framed[20..].* = reply;
    try std.testing.expectEqual(3, replySeq(&framed, false, token));
}

test "echoes over loopback" {
    const io = std.testing.io;
    for ([_]net.IpAddress{ .{ .ip4 = .loopback(0) }, .{ .ip6 = .loopback(0) } }) |target| {
        // Linux allows unprivileged ICMP only per `net.ipv4.ping_group_range`.
        var echo: Echo = Echo.open(io, target) catch |err| return if (builtin.os.tag == .linux) error.SkipZigTest else err;
        defer echo.close(io);
        _ = try echo.ms(io);
        try std.testing.expectEqual(0, try loss(io, target, .{ .count = 5 }));
    }
}
