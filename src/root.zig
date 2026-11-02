//! Measures internet connection quality against Cloudflare's speed test edge:
//! latency, jitter, packet loss, download and upload throughput, how latency
//! degrades while the link is saturated, and which side of the router causes it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gateway = @import("gateway.zig");
const icmp = @import("icmp.zig");
const load = @import("load.zig");
const probe = @import("probe.zig");

pub const Summary = @import("Summary.zig");
pub const Verdict = @import("Verdict.zig");
pub const Load = load.Result;
pub const min_duration = load.min_duration;

pub const Options = struct {
    /// Must serve Cloudflare's `/__down?bytes=N` and `/__up` endpoints.
    host: []const u8 = "speed.cloudflare.com",
    /// Parallel connections per direction.
    streams: u8 = 6,
    /// Longest each of the download and upload phases may run. At least
    /// `min_duration`.
    duration: Io.Duration = .fromSeconds(8),
    /// Data each phase may move. Cloudflare throttles an IP for most of an
    /// hour after about 1 GB in a few seconds; its own test moves ~250 MB.
    max_bytes: u64 = 400_000_000,
    /// Idle latency samples.
    pings: u16 = 20,
    listener: ?Listener = null,
    diagnostics: ?*Diagnostics = null,
};

/// Details of a failed `run`.
pub const Diagnostics = struct {
    /// How long the server asked to wait, with `error.RateLimited`.
    retry_after: ?Io.Duration = null,
};

pub const Phase = enum(u8) { latency, download, upload };

pub const Event = struct {
    phase: Phase,
    /// Milliseconds during `latency`, bits per second otherwise.
    value: f64,
    /// Completion of the current phase in [0, 1].
    progress: f32,
};

/// Called from the thread that called `run`.
pub const Listener = struct {
    context: ?*anyopaque = null,
    onEvent: *const fn (context: ?*anyopaque, event: Event) void,

    fn emit(l: ?Listener, event: Event) void {
        if (l) |listener| listener.onEvent(listener.context, event);
    }
};

pub const Result = struct {
    /// IATA code of the edge that served the test, e.g. "CDG".
    colo: ?[3]u8,
    /// Time to resolve the host, in ms.
    dns: f64,
    /// Idle round trip, in ms.
    latency: Summary,
    /// Mean difference between consecutive idle round trips, in ms.
    jitter: f64,
    /// Fraction of ICMP echoes lost, or null when the system denies ICMP.
    loss: ?f64,
    download: Load,
    upload: Load,
    /// Null when the gateway is unknown or ignores ICMP.
    gateway: ?Gateway,
    /// Null when nothing noticeable slows the connection, or without a gateway.
    verdict: ?Verdict,
};

/// The router this device reaches the internet through.
pub const Gateway = struct {
    /// Reached over Wi-Fi.
    wireless: bool,
    /// Idle echo round trip, in ms.
    latency: Summary,
};

pub fn run(io: Io, gpa: Allocator, options: Options) !Result {
    var ignored: Diagnostics = .{};
    const diagnostics = options.diagnostics orelse &ignored;
    diagnostics.* = .{};
    if (options.duration.toNanoseconds() < min_duration.toNanoseconds()) return error.DurationTooShort;
    const down_url = try std.fmt.allocPrint(gpa, "https://{s}/__down", .{options.host});
    defer gpa.free(down_url);
    const up_url = try std.fmt.allocPrint(gpa, "https://{s}/__up", .{options.host});
    defer gpa.free(up_url);

    const resolved = try probe.resolve(io, options.host, 443);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const colo = try edge(&client, down_url, diagnostics);

    var loss_future = try io.concurrent(icmp.loss, .{ io, resolved.address, .{} });
    defer if (loss_future.cancel(io)) |_| {} else |_| {};

    const router = try gateway.find(io, gpa);
    const gateway_pings = try gpa.alloc(f64, options.pings);
    defer gpa.free(gateway_pings);
    var gateway_future = try io.concurrent(echoes, .{ io, if (router) |r| r.address else null, gateway_pings });
    defer if (gateway_future.cancel(io)) |_| {} else |_| {};

    const pings = try gpa.alloc(f64, options.pings);
    defer gpa.free(pings);
    for (pings, 1..) |*p, i| {
        p.* = try probe.connectMs(io, resolved.address);
        Listener.emit(options.listener, .{
            .phase = .latency,
            .value = p.*,
            .progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pings.len)),
        });
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    const jitter = Summary.jitter(pings);

    const loss: ?f64 = loss_future.await(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => null,
    };
    const gateway_replies = gateway_future.await(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => gateway_pings[0..0],
    };
    const gateway_result: ?Gateway = if (gateway_replies.len > 0) .{
        .wireless = router.?.wireless,
        .latency = .of(gateway_replies),
    } else null;

    const load_options: load.Options = .{
        .streams = options.streams,
        .duration = options.duration,
        .max_bytes = options.max_bytes,
        .down_url = down_url,
        .up_url = up_url,
        .target = resolved.address,
        .gateway = if (gateway_result != null) router.?.address else null,
        .retry_after = &diagnostics.retry_after,
    };
    const latency: Summary = .of(pings);
    const download = try measure(io, gpa, &client, .download, load_options, options.listener);
    const upload = try measure(io, gpa, &client, .upload, load_options, options.listener);
    return .{
        .colo = colo,
        .dns = resolved.ms,
        .latency = latency,
        .jitter = jitter,
        .loss = loss,
        .download = download,
        .upload = upload,
        .gateway = gateway_result,
        .verdict = if (gateway_result) |g| Verdict.of(latency.p50, g.latency.p50, download, upload) else null,
    };
}

/// Fills `out` with echo round trips to `target` and returns those that got a
/// reply, or none without a target.
fn echoes(io: Io, target: ?Io.net.IpAddress, out: []f64) ![]f64 {
    var echo: icmp.Echo = try .open(io, target orelse return out[0..0]);
    defer echo.close(io);
    var len: usize = 0;
    for (out) |_| {
        if (echo.ms(io)) |ms| {
            out[len] = ms;
            len += 1;
        } else |err| switch (err) {
            error.Timeout => {},
            else => |e| return e,
        }
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    return out[0..len];
}

fn measure(io: Io, gpa: Allocator, client: *std.http.Client, direction: load.Direction, options: load.Options, listener: ?Listener) !Load {
    const Tick = struct {
        listener: ?Listener,
        phase: Phase,

        fn onTick(t: @This(), bps: f64, progress: f32) void {
            Listener.emit(t.listener, .{ .phase = t.phase, .value = bps, .progress = progress });
        }
    };
    const phase: Phase = switch (direction) {
        .download => .download,
        .upload => .upload,
    };
    return load.measure(io, gpa, client, direction, options, Tick{ .listener = listener, .phase = phase }, Tick.onTick);
}

/// Returns the edge's location code.
fn edge(client: *std.http.Client, down_url: []const u8, diagnostics: *Diagnostics) !?[3]u8 {
    var uri: std.Uri = try .parse(down_url);
    uri.query = .{ .raw = "bytes=0" };
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
    defer req.deinit();
    try req.sendBodiless();
    const response = try req.receiveHead(&.{});
    switch (response.head.status) {
        .ok => {},
        .forbidden, .too_many_requests => {
            if (load.retryAfter(response.head)) |seconds| diagnostics.retry_after = .fromSeconds(seconds);
            return error.RateLimited;
        },
        else => return error.HttpStatus,
    }
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "colo") and h.value.len == 3) return h.value[0..3].*;
    }
    return null;
}

test {
    _ = gateway;
    _ = icmp;
    _ = Verdict;
    _ = load;
    _ = Summary;
}
