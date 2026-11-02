//! Round trips measured as TCP handshakes, which no server processing delays.
const std = @import("std");
const Io = std.Io;
const net = Io.net;

pub fn connectMs(io: Io, target: net.IpAddress) !f64 {
    const start = Io.Clock.awake.now(io);
    // ponytail: no connect timeout, Zig 0.17's Threaded backend panics on one; a
    // dead route blocks for the OS SYN timeout. Add `.timeout` once std implements it.
    const stream = try target.connect(io, .{ .mode = .stream });
    const elapsed = start.untilNow(io, .awake);
    stream.close(io);
    return ms(elapsed);
}

pub const Resolved = struct {
    address: net.IpAddress,
    ms: f64,
};

/// Resolves `host` and times the lookup.
pub fn resolve(io: Io, host: []const u8, port: u16) !Resolved {
    const name: net.HostName = try .init(host);
    var buf: [16]net.HostName.LookupResult = undefined;
    var results: Io.Queue(net.HostName.LookupResult) = .init(&buf);

    const start = Io.Clock.awake.now(io);
    try name.lookup(io, &results, .{ .port = port });
    const elapsed = start.untilNow(io, .awake);

    while (results.getOne(io)) |result| switch (result) {
        .address => |address| return .{ .address = address, .ms = ms(elapsed) },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => return error.NoAddressReturned,
        error.Canceled => |e| return e,
    }
}

pub fn ms(d: Io.Duration) f64 {
    return @as(f64, @floatFromInt(d.toNanoseconds())) / std.time.ns_per_ms;
}
