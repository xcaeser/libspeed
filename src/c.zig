//! C ABI over `speed.run`, declared in include/speed.h.
const std = @import("std");
const speed = @import("root.zig");

const Options = extern struct {
    host: ?[*:0]const u8,
    streams: u8,
    duration_ms: u32,
    pings: u16,
};

const Summary = extern struct { p10: f64, p50: f64, p90: f64 };

const Load = extern struct {
    bps: Summary,
    latency_ms: Summary,
};

const Result = extern struct {
    colo: [4]u8,
    dns_ms: f64,
    latency_ms: Summary,
    jitter_ms: f64,
    loss: f64,
    download: Load,
    upload: Load,
};

comptime {
    // sdk/ts decodes these by offset.
    std.debug.assert(@sizeOf(Options) == 24);
    std.debug.assert(@sizeOf(Result) == 152);
}

const Status = enum(c_int) { ok, rate_limited, dns, network, out_of_memory, invalid_options };

const ProgressFn = *const fn (context: ?*anyopaque, phase: c_int, value: f64, progress: f32) callconv(.c) void;

const Forward = struct {
    callback: ProgressFn,
    context: ?*anyopaque,

    fn onEvent(context: ?*anyopaque, event: speed.Event) void {
        const f: *const Forward = @ptrCast(@alignCast(context.?));
        f.callback(f.context, @backingInt(event.phase), event.value, event.progress);
    }
};

var threaded: std.Io.Threaded = undefined;
var threaded_state: std.atomic.Value(enum(u8) { none, starting, ready }) = .init(.none);

/// Threaded installs process-wide signal handlers that cancellation relies on,
/// so overlapping runs share one instance, which lives until the process exits.
fn io() std.Io {
    if (threaded_state.cmpxchgStrong(.none, .starting, .acquire, .acquire) == null) {
        threaded = .init(std.heap.smp_allocator, .{});
        threaded_state.store(.ready, .release);
    } else while (threaded_state.load(.acquire) != .ready) std.atomic.spinLoopHint();
    return threaded.io();
}

export fn speed_run(options: ?*const Options, callback: ?ProgressFn, context: ?*anyopaque, out: *Result) Status {
    const gpa = std.heap.smp_allocator;

    var o: speed.Options = .{};
    if (options) |c| {
        if (c.host) |h| o.host = std.mem.span(h);
        if (c.streams != 0) o.streams = c.streams;
        if (c.duration_ms != 0) o.duration = .fromMilliseconds(c.duration_ms);
        if (c.pings != 0) o.pings = c.pings;
    }
    var forward: Forward = undefined;
    if (callback) |cb| {
        forward = .{ .callback = cb, .context = context };
        o.listener = .{ .context = &forward, .onEvent = Forward.onEvent };
    }

    const r = speed.run(io(), gpa, o) catch |err| return switch (err) {
        error.RateLimited => .rate_limited,
        error.OutOfMemory => .out_of_memory,
        error.UnknownHostName, error.NameServerFailure, error.NoAddressReturned => .dns,
        error.DurationTooShort => .invalid_options,
        else => .network,
    };
    out.* = .{
        .colo = if (r.colo) |c| c ++ .{0} else @splat(0),
        .dns_ms = r.dns,
        .latency_ms = summary(r.latency),
        .jitter_ms = r.jitter,
        .loss = r.loss orelse std.math.nan(f64),
        .download = load(r.download),
        .upload = load(r.upload),
    };
    return .ok;
}

fn summary(s: speed.Summary) Summary {
    return .{ .p10 = s.p10, .p50 = s.p50, .p90 = s.p90 };
}

fn load(l: speed.Load) Load {
    return .{
        .bps = summary(l.bps),
        .latency_ms = summary(l.latency),
    };
}
