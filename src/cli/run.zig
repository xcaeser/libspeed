const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const speed = @import("speed");

pub fn command(options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(options, .{
        .name = "run",
        .description = "Run a speed test against the nearest Cloudflare edge",
    }, exec);
    try cmd.addFlag(.{
        .name = "json",
        .description = "Print the result as JSON",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn exec(ctx: zli.CommandContext) !void {
    const w = ctx.writer;
    const json = ctx.flag("json", bool);
    const tty = try Io.File.stdout().isTty(ctx.io);

    var live: Live = .{ .w = w };
    var diagnostics: speed.Diagnostics = .{};
    var options: speed.Options = .{ .diagnostics = &diagnostics };
    if (tty and !json) options.listener = .{ .context = &live, .onEvent = Live.onEvent };

    const result = speed.run(ctx.io, ctx.allocator, options) catch |err| {
        if (tty and !json) try w.writeAll(clear_line);
        switch (err) {
            error.RateLimited => {
                try w.writeAll("Cloudflare is throttling this connection. Try again ");
                if (diagnostics.retry_after) |d|
                    try w.print("in {d} minutes.\n", .{@divFloor(d.toSeconds() + 59, 60)})
                else
                    try w.writeAll("later.\n");
            },
            error.UnknownHostName, error.NameServerFailure, error.NoAddressReturned => try w.writeAll("Could not resolve speed.cloudflare.com. Check your connection.\n"),
            else => return err,
        }
        try w.flush();
        std.process.exit(1);
    };

    if (json) {
        try std.json.Stringify.value(Json.of(&result), .{ .whitespace = .indent_2 }, w);
        return w.writeByte('\n');
    }
    if (tty) try w.writeAll(clear_line);
    try report(w, result, tty);
}

const clear_line = "\r\x1b[2K";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

/// Redraws one line per tick: the phase, its current value and a progress bar.
const Live = struct {
    w: *Io.Writer,

    fn onEvent(context: ?*anyopaque, event: speed.Event) void {
        const live: *Live = @ptrCast(@alignCast(context.?));
        live.draw(event) catch {};
    }

    fn draw(l: *Live, e: speed.Event) !void {
        var buf: [32]u8 = undefined;
        const value = switch (e.phase) {
            .latency => try ms(&buf, e.value),
            .download, .upload => try rate(&buf, e.value),
        };
        const label = switch (e.phase) {
            .latency => "Latency",
            .download => "Download",
            .upload => "Upload",
        };
        try l.w.print(clear_line ++ "  {s:<10}" ++ bold ++ "{s:>10}" ++ reset ++ "  ", .{ label, value });
        const width = 24;
        const filled: usize = @intFromFloat(@round(std.math.clamp(e.progress, 0, 1) * width));
        try l.w.splatBytesAll("━", filled);
        try l.w.writeAll(dim);
        try l.w.splatBytesAll("─", width - filled);
        try l.w.writeAll(reset);
        try l.w.flush();
    }
};

fn report(w: *Io.Writer, r: speed.Result, color: bool) !void {
    const b = if (color) bold else "";
    const d = if (color) dim else "";
    const x = if (color) reset else "";
    var v: [32]u8 = undefined;
    var s: [32]u8 = undefined;

    try w.print("  {s:<10}{s}{s:>10}{s}  {s}{s}{s}\n", .{ "Download", b, try rate(&v, r.download.bps.p50), x, d, try loaded(&s, r.download.latency.p50), x });
    try w.print("  {s:<10}{s}{s:>10}{s}  {s}{s}{s}\n", .{ "Upload", b, try rate(&v, r.upload.bps.p50), x, d, try loaded(&s, r.upload.latency.p50), x });
    try w.print("  {s:<10}{s}{s:>10}{s}  {s}jitter {s}{s}\n", .{ "Latency", b, try ms(&v, r.latency.p50), x, d, try ms(&s, r.jitter), x });
    try w.print("  {s:<10}{s}{s:>10}{s}\n", .{ "Loss", b, if (r.loss) |l| try percent(&v, l) else "–", x });
    if (r.gateway) |g| {
        try w.print("  {s:<10}{s}{s:>10}{s}", .{ if (g.wireless) "Wi-Fi" else "Router", b, try ms(&v, g.latency.p50), x });
        if (busiest(r.download.gateway_latency, r.upload.gateway_latency)) |busy| try w.print("  {s}{s}{s}", .{ d, try loaded(&s, busy), x });
        try w.writeByte('\n');
    }
    if (r.verdict) |verdict| try w.print("\n{f}", .{Advice{ .verdict = verdict, .wireless = r.gateway.?.wireless }});
    if (r.colo) |c| try w.print("\n  {s}Cloudflare {s}{s}\n", .{ d, &c, x });
}

/// The higher of two loaded p50s, either of which may be unknown.
fn busiest(a: ?speed.Summary, b: ?speed.Summary) ?f64 {
    const x = a orelse return if (b) |y| y.p50 else null;
    const y = b orelse return x.p50;
    return @max(x.p50, y.p50);
}

/// Where the delay comes from, what it does, and what to do about it.
const Advice = struct {
    verdict: speed.Verdict,
    wireless: bool,

    pub fn format(a: Advice, w: *Io.Writer) Io.Writer.Error!void {
        const v = a.verdict;
        const culprit = switch (v.segment) {
            .local => if (a.wireless) "Your Wi-Fi" else "Your home network",
            .isp => "Your internet line",
        };
        const when = switch (v.phase) {
            .latency => "to every request",
            .download => "while downloading",
            .upload => "while uploading",
        };
        try w.print("  {s} adds {d:.0} ms {s}, enough for calls and games to feel it.\n", .{ culprit, v.added, when });
        try w.writeAll(switch (v.segment) {
            .local => if (!a.wireless) "" else if (v.phase == .latency) "  Moving closer to the router helps.\n" else "  Ethernet avoids it.\n",
            .isp => "  Smart queue management (SQM) on your router fixes it.\n",
        });
    }
};

fn loaded(buf: []u8, latency: f64) ![]const u8 {
    var m: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} under load", .{try ms(&m, latency)});
}

fn rate(buf: []u8, bps: f64) ![]const u8 {
    const mbps = bps / 1e6;
    if (mbps >= 1000) return std.fmt.bufPrint(buf, "{d:.2} Gbps", .{mbps / 1000});
    if (mbps >= 100) return std.fmt.bufPrint(buf, "{d:.0} Mbps", .{mbps});
    return std.fmt.bufPrint(buf, "{d:.1} Mbps", .{mbps});
}

fn ms(buf: []u8, value: f64) ![]const u8 {
    if (value >= 100) return std.fmt.bufPrint(buf, "{d:.0} ms", .{value});
    return std.fmt.bufPrint(buf, "{d:.1} ms", .{value});
}

fn percent(buf: []u8, fraction: f64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}%", .{fraction * 100});
}

/// Explicit units, since scripts read this.
const Json = struct {
    server: ?[]const u8,
    dns_ms: f64,
    latency_ms: speed.Summary,
    jitter_ms: f64,
    loss: ?f64,
    download: Load,
    upload: Load,
    gateway: ?Gateway,
    verdict: ?Verdict,

    const Load = struct {
        bps: speed.Summary,
        latency_ms: speed.Summary,
        gateway_latency_ms: ?speed.Summary,

        fn of(l: speed.Load) Load {
            return .{ .bps = l.bps, .latency_ms = l.latency, .gateway_latency_ms = l.gateway_latency };
        }
    };

    const Gateway = struct {
        wireless: bool,
        latency_ms: speed.Summary,
    };

    const Verdict = struct {
        segment: speed.Verdict.Segment,
        /// "latency" for every request, else the direction under load.
        phase: speed.Phase,
        added_ms: f64,
    };

    fn of(r: *const speed.Result) Json {
        return .{
            .server = if (r.colo) |*c| c else null,
            .dns_ms = r.dns,
            .latency_ms = r.latency,
            .jitter_ms = r.jitter,
            .loss = r.loss,
            .download = .of(r.download),
            .upload = .of(r.upload),
            .gateway = if (r.gateway) |g| .{ .wireless = g.wireless, .latency_ms = g.latency } else null,
            .verdict = if (r.verdict) |v| .{ .segment = v.segment, .phase = v.phase, .added_ms = v.added } else null,
        };
    }
};

test rate {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("9.4 Mbps", try rate(&buf, 9.43e6));
    try std.testing.expectEqualStrings("938 Mbps", try rate(&buf, 938.2e6));
    try std.testing.expectEqualStrings("1.24 Gbps", try rate(&buf, 1.2449e9));
}
