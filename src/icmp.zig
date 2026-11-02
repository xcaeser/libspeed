//! Packet loss over unprivileged ICMP echo (SOCK_DGRAM + IPPROTO_ICMP).
//! Works without root on macOS, and on Linux when `net.ipv4.ping_group_range`
//! includes the user. Elsewhere `loss` fails and the caller reports it as unknown.
const std = @import("std");
const Io = std.Io;
const net = Io.net;

const header_len = 8;
const token_len = 8;

pub const Options = struct {
    count: u16 = 50,
    interval: Io.Duration = .fromMilliseconds(20),
    timeout: Io.Duration = .fromMilliseconds(1000),
};

/// Returns the fraction of echo requests that got no reply in [0, 1].
pub fn loss(io: Io, target: net.IpAddress, options: Options) !f64 {
    const v6 = target == .ip6;
    const local: net.IpAddress = if (v6) .{ .ip6 = .unspecified(0) } else .{ .ip4 = .unspecified(0) };
    const socket = try local.bind(io, .{ .mode = .dgram, .protocol = if (v6) .icmpv6 else .icmp });
    defer socket.close(io);

    var token: [token_len]u8 = undefined;
    io.random(&token);

    var received: u16 = 0;
    for (0..options.count) |i| {
        const seq: u16 = @intCast(i);
        const request = echoRequest(v6, seq, token);
        try socket.send(io, &target, &request);
        if (try awaitReply(io, socket, v6, seq, token, options.timeout)) received += 1;
        try io.sleep(options.interval, .awake);
    }
    return 1 - @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(options.count));
}

fn awaitReply(io: Io, socket: net.Socket, v6: bool, seq: u16, token: [token_len]u8, timeout: Io.Duration) !bool {
    const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = timeout, .clock = .awake } }).toDeadline(io);
    var buf: [1500]u8 = undefined;
    while (true) {
        const message = socket.receiveTimeout(io, &buf, deadline) catch |err| switch (err) {
            error.Timeout => return false,
            else => |e| return e,
        };
        if (isReply(message.data, v6, seq, token)) return true;
    }
}

fn echoRequest(v6: bool, seq: u16, token: [token_len]u8) [header_len + token_len]u8 {
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

fn isReply(data: []const u8, v6: bool, seq: u16, token: [token_len]u8) bool {
    var icmp = data;
    // macOS delivers IPv4 replies with their IP header attached.
    if (!v6 and icmp.len > 0 and icmp[0] >> 4 == 4) {
        const ihl = @as(usize, icmp[0] & 0x0f) * 4;
        if (icmp.len < ihl) return false;
        icmp = icmp[ihl..];
    }
    if (icmp.len < header_len + token_len) return false;
    return icmp[0] == @as(u8, if (v6) 129 else 0) and
        std.mem.readInt(u16, icmp[6..8], .big) == seq and
        std.mem.eql(u8, icmp[header_len..][0..token_len], &token);
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
    try std.testing.expect(isReply(&reply, false, 3, token));
    try std.testing.expect(!isReply(&reply, false, 4, token));
    try std.testing.expect(!isReply(&reply, false, 3, "zzzzzzzz".*));

    // Same reply behind a 20-byte IPv4 header, as macOS delivers it.
    var framed: [20 + reply.len]u8 = @splat(0);
    framed[0] = 0x45;
    framed[20..].* = reply;
    try std.testing.expect(isReply(&framed, false, 3, token));
}
