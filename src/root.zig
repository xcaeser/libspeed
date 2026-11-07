//! Measures internet connection quality against Cloudflare's speed test edge,
//! or a host over ssh: latency, jitter, packet loss, download and upload
//! throughput, how latency degrades while the link is saturated, and which
//! side of the router causes it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gateway = @import("gateway.zig");
const icmp = @import("icmp.zig");
const load = @import("load.zig");
const meta = @import("meta.zig");
const probe = @import("probe.zig");
const ssh = @import("ssh.zig");

pub const Summary = @import("Summary.zig");
pub const Verdict = @import("Verdict.zig");
pub const Load = load.Result;
pub const Isp = meta.Isp;
pub const min_duration = load.min_duration;

pub const Target = union(enum) {
    /// A host that serves Cloudflare's `/__down?bytes=N` and `/__up` endpoints,
    /// and may serve `/meta` to name the edge and network.
    cloudflare: []const u8,
    /// A destination as `ssh` takes it: a ~/.ssh/config alias, `user@host` or
    /// `ssh://user@host:port`. Throughput is what ssh streams carry, so it
    /// includes ssh's encryption and flow control.
    ssh: []const u8,
};

pub const Options = struct {
    target: Target = .{ .cloudflare = "speed.cloudflare.com" },
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
    /// The network this device reaches the internet through; null when unknown.
    isp: ?Isp,
    /// Time to resolve the host, in ms; 0 over ssh.
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
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var down_buf: [300]u8 = undefined;
    var up_buf: [300]u8 = undefined;

    var echo: ?ssh.Echo = null;
    defer if (echo) |*e| e.close(io);
    // Over ssh the echo session logs in first, so ssh explains any failure.
    const address: ?Io.net.IpAddress, const dns: f64, const identity: meta.Meta, const server: load.Server = switch (options.target) {
        .cloudflare => |host| blk: {
            const down: std.Uri = try .parse(try std.fmt.bufPrint(&down_buf, "https://{s}/__down", .{host}));
            const up: std.Uri = try .parse(try std.fmt.bufPrint(&up_buf, "https://{s}/__up", .{host}));
            const resolved = try probe.resolve(io, host, 443);
            break :blk .{ resolved.address, resolved.ms, try meta.fetch(&client, gpa, host), .{ .https = .{ .client = &client, .down = down, .up = up } } };
        },
        .ssh => |destination| blk: {
            echo = try .open(io, destination);
            break :blk .{ try ssh.address(io, gpa, destination), 0, .{ .colo = null, .isp = null }, .{ .ssh = destination } };
        },
    };

    var loss_future = try io.concurrent(lossTo, .{ io, address });
    defer if (loss_future.cancel(io)) |_| {} else |_| {};

    const router = try gateway.find(io, gpa);
    const gateway_pings = try gpa.alloc(f64, options.pings);
    defer gpa.free(gateway_pings);
    var gateway_future = try io.concurrent(echoes, .{ io, if (router) |r| r.address else null, gateway_pings });
    defer if (gateway_future.cancel(io)) |_| {} else |_| {};

    const latency_probe: load.Latency = if (echo) |*e| .{ .ssh = e } else .{ .connect = address.? };
    const pings = try gpa.alloc(f64, options.pings);
    defer gpa.free(pings);
    for (pings, 1..) |*p, i| {
        p.* = try latency_probe.ms(io);
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
        .server = server,
        .latency = latency_probe,
        .gateway = if (gateway_result != null) router.?.address else null,
        .retry_after = &diagnostics.retry_after,
    };
    const latency: Summary = .of(pings);
    const download = try measure(io, gpa, .download, load_options, options.listener);
    const upload = try measure(io, gpa, .upload, load_options, options.listener);
    return .{
        .colo = identity.colo,
        .isp = identity.isp,
        .dns = dns,
        .latency = latency,
        .jitter = jitter,
        .loss = loss,
        .download = download,
        .upload = upload,
        .gateway = gateway_result,
        .verdict = if (gateway_result) |g| Verdict.of(latency.p50, g.latency.p50, download, upload) else null,
    };
}

fn lossTo(io: Io, target: ?Io.net.IpAddress) !f64 {
    return icmp.loss(io, target orelse return error.NoAddress, .{});
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

fn measure(io: Io, gpa: Allocator, direction: load.Direction, options: load.Options, listener: ?Listener) !Load {
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
    return load.measure(io, gpa, direction, options, Tick{ .listener = listener, .phase = phase }, Tick.onTick);
}

test {
    _ = gateway;
    _ = icmp;
    _ = Verdict;
    _ = load;
    _ = meta;
    _ = Summary;
    _ = ssh;
}
