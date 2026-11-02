//! Saturates the link with parallel HTTP streams and samples throughput and
//! latency under load.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;

const Summary = @import("Summary.zig");
const probe = @import("probe.zig");

pub const Direction = enum { download, upload };

pub const Result = struct {
    /// Bits per second over a sliding window, after the ramp-up is discarded.
    bps: Summary,
    /// TCP connect time to the server while the link is saturated, in ms.
    latency: Summary,
    /// Fraction of segments the server retransmitted. Download only.
    retransmits: ?f64,
};

pub const Options = struct {
    streams: u8,
    duration: Io.Duration,
    down_url: []const u8,
    up_url: []const u8,
    target: Io.net.IpAddress,
    /// Set to the server's Retry-After when it throttles this IP.
    retry_after: *?Io.Duration,
};

const tick: Io.Duration = .fromMilliseconds(100);
/// Throughput samples average over this many ticks.
const window = 5;
/// The first quarter of the run is TCP slow start and TLS handshakes.
const ramp_divisor = 4;
/// Steady-state ticks needed to report a phase the server cut short.
const min_steady = 10;
const ping_interval: Io.Duration = .fromMilliseconds(200);

const Shared = struct {
    io: Io,
    direction: Direction,
    uri: std.Uri,
    bytes: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    rate_limited: std.atomic.Value(bool) = .init(false),
    /// Seconds; 0 when unknown.
    retry_after: std.atomic.Value(u32) = .init(0),
};

const Worker = struct {
    shared: *Shared,
    client: http.Client,
    tcp: TcpStats = .{},
    banked: TcpStats = .{},

    fn run(w: *Worker) Io.Cancelable!void {
        const io = w.shared.io;
        var size: u64 = 1 << 20;
        while (!w.shared.stop.load(.acquire)) {
            const start = Io.Clock.awake.now(io);
            w.transfer(size) catch |err| {
                switch (err) {
                    error.Canceled => return error.Canceled,
                    // Retrying only extends the server's penalty.
                    error.RateLimited => return w.shared.rate_limited.store(true, .release),
                    else => std.log.debug("{t} stream failed: {t}", .{ w.shared.direction, err }),
                }
                try io.sleep(.fromMilliseconds(250), .awake);
                continue;
            };
            // Size the next request to take about a quarter second.
            const ns: u64 = @intCast(@max(1, start.untilNow(io, .awake).toNanoseconds()));
            size = std.math.clamp(size * std.time.ns_per_s / 4 / ns, 64 << 10, 8 << 20); // Cloudflare throttles an IP for most of an hour once it fetches 10 MB+ too often.
        }
    }

    fn transfer(w: *Worker, size: u64) !void {
        const s = w.shared;
        var uri = s.uri;
        var query_buf: [32]u8 = undefined;
        if (s.direction == .download) uri.query = .{ .raw = try std.fmt.bufPrint(&query_buf, "bytes={d}", .{size}) };

        var req = try w.client.request(if (s.direction == .download) .GET else .POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .accept_encoding = .omit },
        });
        defer req.deinit();

        switch (s.direction) {
            .download => try req.sendBodiless(),
            .upload => {
                req.transfer_encoding = .{ .content_length = size };
                var buf: [16 << 10]u8 = undefined;
                var body = try req.sendBodyUnflushed(&buf);
                const zeros: [64 << 10]u8 = @splat(0);
                var left = size;
                while (left > 0 and !s.stop.load(.acquire)) {
                    const n = @min(left, zeros.len);
                    try body.writer.writeAll(zeros[0..n]);
                    try body.flush();
                    try req.connection.?.flush();
                    _ = s.bytes.fetchAdd(n, .monotonic);
                    left -= n;
                }
                if (left > 0) return;
                try body.end();
                try req.connection.?.flush();
            },
        }

        var response = try req.receiveHead(&.{});
        switch (response.head.status) {
            .ok => {},
            .forbidden, .too_many_requests => {
                if (retryAfter(response.head)) |seconds| _ = s.retry_after.fetchMax(seconds, .monotonic);
                return error.RateLimited;
            },
            else => return error.HttpStatus,
        }
        if (s.direction == .download) w.recordTcp(response.head);

        const body = response.reader(&.{});
        while (!s.stop.load(.acquire)) {
            const n = body.discard(.limited(64 << 10)) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return response.bodyErr() orelse req.connection.?.getReadError().?,
            };
            if (s.direction == .download) _ = s.bytes.fetchAdd(n, .monotonic);
        }
    }

    /// Cloudflare reports the server's cumulative TCP counters per connection
    /// in `server-timing: cfL4;desc="?...&sent=N&retrans=N&cid=X..."`.
    fn recordTcp(w: *Worker, head: http.Client.Response.Head) void {
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "server-timing")) continue;
            const stats = TcpStats.parse(h.value) orelse continue;
            if (stats.cid != w.tcp.cid) {
                w.banked.sent += w.tcp.sent;
                w.banked.retrans += w.tcp.retrans;
            }
            w.tcp = stats;
        }
    }
};

const TcpStats = struct {
    cid: u64 = 0,
    sent: u64 = 0,
    retrans: u64 = 0,

    fn parse(value: []const u8) ?TcpStats {
        const start = std.mem.find(u8, value, "cfL4;desc=\"?") orelse return null;
        const rest = value[start + "cfL4;desc=\"?".len ..];
        const params = rest[0 .. std.mem.findScalar(u8, rest, '"') orelse rest.len];
        var stats: TcpStats = .{};
        var seen: u2 = 0;
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |kv| {
            const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
            const key, const val = .{ kv[0..eq], kv[eq + 1 ..] };
            if (std.mem.eql(u8, key, "sent")) {
                stats.sent = std.fmt.parseInt(u64, val, 10) catch return null;
                seen += 1;
            } else if (std.mem.eql(u8, key, "retrans")) {
                stats.retrans = std.fmt.parseInt(u64, val, 10) catch return null;
                seen += 1;
            } else if (std.mem.eql(u8, key, "cid")) {
                stats.cid = std.fmt.parseInt(u64, val, 16) catch return null;
            }
        }
        return if (seen == 2) stats else null;
    }
};

const Pinger = struct {
    shared: *Shared,
    target: Io.net.IpAddress,
    samples: []f64,
    len: usize = 0,

    fn run(p: *Pinger) Io.Cancelable!void {
        const io = p.shared.io;
        while (!p.shared.stop.load(.acquire) and p.len < p.samples.len) {
            if (probe.connectMs(io, p.target)) |ms| {
                p.samples[p.len] = ms;
                p.len += 1;
            } else |err| {
                if (err == error.Canceled) return error.Canceled;
            }
            try io.sleep(ping_interval, .awake);
        }
    }
};

/// Calls `onTick(context, bps, progress)` every tick from the calling thread.
pub fn measure(
    io: Io,
    gpa: Allocator,
    /// Its CA bundle is shared read-only with the stream clients.
    primed: *const http.Client,
    direction: Direction,
    options: Options,
    context: anytype,
    comptime onTick: fn (@TypeOf(context), f64, f32) void,
) !Result {
    var shared: Shared = .{
        .io = io,
        .direction = direction,
        .uri = try .parse(if (direction == .download) options.down_url else options.up_url),
    };

    const duration_ns: u64 = @intCast(options.duration.toNanoseconds());
    const tick_ns: u64 = @intCast(tick.toNanoseconds());
    const ticks = try gpa.alloc(u64, duration_ns / tick_ns + 1);
    defer gpa.free(ticks);
    const pings = try gpa.alloc(f64, duration_ns / @as(u64, @intCast(ping_interval.toNanoseconds())) + 1);
    defer gpa.free(pings);
    const workers = try gpa.alloc(Worker, options.streams);
    defer gpa.free(workers);

    for (workers) |*w| w.* = .{
        .shared = &shared,
        .client = .{ .allocator = gpa, .io = io, .ca_bundle = primed.ca_bundle, .now = primed.now },
    };
    defer for (workers) |*w| {
        // The bundle belongs to `primed`.
        w.client.ca_bundle = .empty;
        w.client.deinit();
    };
    var pinger: Pinger = .{ .shared = &shared, .target = options.target, .samples = pings };

    var group: Io.Group = .init;
    defer group.cancel(io);
    for (workers) |*w| try group.concurrent(io, Worker.run, .{w});
    try group.concurrent(io, Pinger.run, .{&pinger});

    const start = Io.Clock.awake.now(io);
    ticks[0] = 0;
    var len: usize = 1;
    while (len < ticks.len) {
        const at = start.addDuration(.fromNanoseconds(@intCast(len * tick_ns)));
        try (Io.Timeout{ .deadline = .{ .raw = at, .clock = .awake } }).sleep(io);
        ticks[len] = shared.bytes.load(.monotonic);
        len += 1;
        const from = len -| window - 1;
        onTick(context, bps(ticks[from..len], tick_ns), @as(f32, @floatFromInt(len - 1)) / @as(f32, @floatFromInt(ticks.len - 1)));
        if (len * 2 >= ticks.len and settled(ticks[0..len])) break;
        // A throttled stream would make the rest of the phase look slower than
        // the link is; ticks before this one were all streams flowing.
        if (shared.rate_limited.load(.acquire)) {
            len -= 1;
            break;
        }
    }
    shared.stop.store(true, .release);
    group.cancel(io);

    const first = @max(window, len / ramp_divisor);
    if (shared.rate_limited.load(.acquire) and len < first + min_steady) {
        const seconds = shared.retry_after.load(.monotonic);
        if (seconds != 0) options.retry_after.* = .fromSeconds(seconds);
        return error.RateLimited;
    }
    if (ticks[len - 1] == 0) return error.NoThroughput;

    var samples: std.ArrayList(f64) = .empty;
    defer samples.deinit(gpa);
    for (first..len) |i| try samples.append(gpa, bps(ticks[i - window ..][0 .. window + 1], tick_ns));

    var sent: u64 = 0;
    var retrans: u64 = 0;
    for (workers) |w| {
        sent += w.banked.sent + w.tcp.sent;
        retrans += w.banked.retrans + w.tcp.retrans;
    }

    return .{
        .bps = .of(samples.items),
        .latency = .of(pings[0..pinger.len]),
        .retransmits = if (sent == 0) null else @as(f64, @floatFromInt(retrans)) / @as(f64, @floatFromInt(sent)),
    };
}

/// The last second's throughput is within 5% of the second before it, so
/// more data would not change the result, only cost the user's quota.
fn settled(counts: []const u64) bool {
    const second = 10;
    if (counts.len < 2 * second + 1) return false;
    const last = counts[counts.len - 1] - counts[counts.len - 1 - second];
    const prior = counts[counts.len - 1 - second] - counts[counts.len - 1 - 2 * second];
    const diff = @max(last, prior) - @min(last, prior);
    return prior > 0 and diff * 100 <= prior * 5;
}

pub fn retryAfter(head: http.Client.Response.Head) ?u32 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) return std.fmt.parseInt(u32, h.value, 10) catch null;
    }
    return null;
}

/// Bits per second across consecutive cumulative byte counts one tick apart.
fn bps(counts: []const u64, tick_ns: u64) f64 {
    if (counts.len < 2) return 0;
    const bytes: f64 = @floatFromInt(counts[counts.len - 1] - counts[0]);
    const seconds = @as(f64, @floatFromInt((counts.len - 1) * tick_ns)) / std.time.ns_per_s;
    return bytes * 8 / seconds;
}

test "TcpStats.parse" {
    const v = "cfL4;desc=\"?proto=TCP&rtt=12795&sent=38976&recv=259&lost=0&retrans=12&cid=23fec116483e7e8f&x=0\"";
    try std.testing.expectEqual(TcpStats{ .cid = 0x23fec116483e7e8f, .sent = 38976, .retrans = 12 }, TcpStats.parse(v).?);
    try std.testing.expectEqual(null, TcpStats.parse("cfSpeedEdge;dur=3"));
}

test settled {
    var steady: [21]u64 = undefined;
    for (&steady, 0..) |*c, i| c.* = i * 1000;
    try std.testing.expect(settled(&steady));

    var ramping: [21]u64 = undefined;
    for (&ramping, 0..) |*c, i| c.* = i * i * 1000;
    try std.testing.expect(!settled(&ramping));
    try std.testing.expect(!settled(steady[0..20]));
}

test bps {
    try std.testing.expectEqual(@as(f64, 8_000_000), bps(&.{ 0, 100_000, 200_000 }, 100 * std.time.ns_per_ms));
}
