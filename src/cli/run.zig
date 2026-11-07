const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const speed = @import("speed");
const history = @import("history.zig");

pub fn command(options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(options, .{
        .name = "run",
        .description = "Run a speed test against the nearest Cloudflare edge",
        .shortcut = "r",
    }, exec);
    try cmd.addFlag(.{
        .name = "json",
        .description = "Print the result as JSON",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "explain",
        .description = "Say what each figure means",
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

    const usual = remember(ctx, &result);
    if (json) {
        try std.json.Stringify.value(Json.of(&result), .{ .whitespace = .indent_2 }, w);
        return w.writeByte('\n');
    }
    if (tty) try w.writeAll(clear_line);
    try report(w, result, usual, .{ .color = tty, .explain = ctx.flag("explain", bool) });
}

/// Appends the run to the history and returns what is usual on this network.
/// Best effort: a test result is never lost because history could not be written.
fn remember(ctx: zli.CommandContext, r: *const speed.Result) ?history.Rates {
    const entry = std.json.Stringify.valueAlloc(ctx.allocator, Json.of(r), .{}) catch |err| {
        std.log.debug("history: {t}", .{err});
        return null;
    };
    defer ctx.allocator.free(entry);
    const key: ?history.Key = if (r.isp) |isp| .{ .asn = isp.asn, .wireless = if (r.gateway) |g| g.wireless else null } else null;
    return history.record(ctx.io, ctx.allocator, ctx.getContextData(std.process.Environ.Map), key, entry) catch |err| {
        std.log.debug("history: {t}", .{err});
        return null;
    };
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

const Style = struct { color: bool, explain: bool };

fn report(w: *Io.Writer, r: speed.Result, usual: ?history.Rates, style: Style) !void {
    const b = if (style.color) bold else "";
    const d = if (style.color) dim else "";
    const x = if (style.color) reset else "";
    var v: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    const note: Note = .{ .w = w, .style = style };

    try loadRow(w, "Download", r.download, if (usual) |u| u.download else null, style.color);
    try note.transfer("A 1 GB download", r.download, r.latency.p50);
    try loadRow(w, "Upload", r.upload, if (usual) |u| u.upload else null, style.color);
    try note.transfer("Sending 1 GB", r.upload, r.latency.p50);
    try w.print("  {s:<10}{s}{s:>10}{s}  {s}jitter {s}{s}\n", .{ "Latency", b, try ms(&v, r.latency.p50), x, d, try ms(&s, r.jitter), x });
    // Microsoft rates jitter under 30 ms good for calls, and loss under 1%.
    try note.line("Reply time from Cloudflare; jitter is how much it varies, fine under 30 ms.", .{});
    try w.print("  {s:<10}{s}{s:>10}{s}\n", .{ "Loss", b, if (r.loss) |l| try percent(&v, l) else "–", x });
    if (r.loss != null)
        try note.line("Pings to Cloudflare that got no reply; calls suffer if it stays above 1%.", .{})
    else
        try note.line("Pings are blocked here, so loss could not be measured.", .{});
    if (r.gateway) |g| {
        try w.print("  {s:<10}{s}{s:>10}{s}", .{ if (g.wireless) "Wi-Fi" else "Router", b, try ms(&v, g.latency.p50), x });
        if (busiest(r.download.gateway_latency, r.upload.gateway_latency)) |busy| try w.print("  {s}{s}{s}", .{ d, try loaded(&s, busy), x });
        try w.writeByte('\n');
        try note.line("Replies from your router alone: delay here is yours, not your ISP's.", .{});
    }
    if (r.verdict) |verdict| try w.print("\n{f}", .{Advice{ .verdict = verdict, .wireless = r.gateway.?.wireless }});
    if (r.isp != null or r.colo != null) {
        try w.print("\n  {s}", .{d});
        if (r.isp) |*isp| try w.writeAll(isp.name());
        if (r.isp != null and r.colo != null) try w.writeAll(" · ");
        if (r.colo) |c| try w.print("Cloudflare {s}", .{&c});
        try w.print("{s}\n", .{x});
        try note.line("{s}", .{if (r.colo == null)
            "Your provider, as Cloudflare names it."
        else if (r.isp == null)
            "The Cloudflare site that answered, by airport code."
        else
            "Your provider, and the Cloudflare site that answered, by airport code."});
    }
}

/// With --explain, one dim line under a row saying what its figure means.
const Note = struct {
    w: *Io.Writer,
    style: Style,

    fn line(n: Note, comptime fmt: []const u8, args: anytype) !void {
        if (!n.style.explain) return;
        try n.w.print("    {s}" ++ fmt ++ "{s}\n", .{if (n.style.color) dim else ""} ++ args ++ .{if (n.style.color) reset else ""});
    }

    /// How long 1 GB takes at this rate, and the reply time while it runs next to idle.
    fn transfer(n: Note, what: []const u8, l: speed.Load, idle: f64) !void {
        if (l.bps.p50 <= 0) return;
        var t: [32]u8 = undefined;
        var m: [16]u8 = undefined;
        var i: [16]u8 = undefined;
        try n.line("{s} takes {s}; replies take {s} meanwhile ({s} idle).", .{ what, try duration(&t, 8e9 / l.bps.p50), try ms(&m, l.latency.p50), try ms(&i, idle) });
    }
};

/// A rate with its loaded latency, and what is usual when this run is 20% or more away from it.
fn loadRow(w: *Io.Writer, label: []const u8, l: speed.Load, usual: ?f64, color: bool) !void {
    const b = if (color) bold else "";
    const d = if (color) dim else "";
    const x = if (color) reset else "";
    var v: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    try w.print("  {s:<10}{s}{s:>10}{s}  {s}{s}", .{ label, b, try rate(&v, l.bps.p50), x, d, try loaded(&s, l.latency.p50) });
    if (usual) |u| if (u > 0 and @abs(l.bps.p50 - u) / u >= 0.2) try w.print("  usually {s}", .{try rate(&v, u)});
    try w.print("{s}\n", .{x});
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

fn duration(buf: []u8, seconds: f64) ![]const u8 {
    if (seconds < 10) return std.fmt.bufPrint(buf, "{d:.1} s", .{seconds});
    const whole: u64 = @intFromFloat(@round(seconds));
    if (whole < 60) return std.fmt.bufPrint(buf, "{d} s", .{whole});
    if (whole < 600 and whole % 60 != 0) return std.fmt.bufPrint(buf, "{d} min {d} s", .{ whole / 60, whole % 60 });
    const minutes = (whole + 30) / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d} min", .{minutes});
    if (minutes % 60 == 0) return std.fmt.bufPrint(buf, "{d} h", .{minutes / 60});
    return std.fmt.bufPrint(buf, "{d} h {d} min", .{ minutes / 60, minutes % 60 });
}

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
    isp: ?Isp,
    dns_ms: f64,
    latency_ms: speed.Summary,
    jitter_ms: f64,
    loss: ?f64,
    download: Load,
    upload: Load,
    gateway: ?Gateway,
    verdict: ?Verdict,

    const Isp = struct { name: []const u8, asn: u32 };

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
            .isp = if (r.isp) |*isp| .{ .name = isp.name(), .asn = isp.asn } else null,
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

/// A run on Orange at 1 Gbps both ways, through an unknown router.
fn testResult() speed.Result {
    const summary = struct {
        fn of(v: f64) speed.Summary {
            return .{ .p10 = v, .p50 = v, .p90 = v };
        }
    }.of;
    const load: speed.Load = .{ .bps = summary(1e9), .latency = summary(20), .gateway_latency = null };
    var orange = std.mem.zeroes([63]u8);
    @memcpy(orange[0..11], "Orange S.A.");
    return .{
        .colo = "CDG".*,
        .isp = .{ .asn = 3215, .len = 11, .buf = orange },
        .dns = 1,
        .latency = summary(8),
        .jitter = 1,
        .loss = 0,
        .download = load,
        .upload = load,
        .gateway = null,
        .verdict = null,
    };
}

test "report shows the usual rate only when a rate is far from it" {
    const result = testResult();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try report(&w, result, .{ .download = 1.25e9, .upload = 1e9 }, .{ .color = false, .explain = false });
    const out = w.buffered();
    const download = out[0..std.mem.findScalar(u8, out, '\n').?];
    try std.testing.expect(std.mem.endsWith(u8, download, "usually 1.25 Gbps"));
    try std.testing.expectEqual(1, std.mem.count(u8, out, "usually"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\n  Orange S.A. · Cloudflare CDG\n"));

    w = .fixed(&buf);
    try report(&w, result, .{ .download = 1.1e9, .upload = 0.9e9 }, .{ .color = false, .explain = false });
    try std.testing.expectEqual(0, std.mem.count(u8, w.buffered(), "usually"));
}

test duration {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.8 s", try duration(&buf, 0.8));
    try std.testing.expectEqualStrings("17 s", try duration(&buf, 16.6));
    try std.testing.expectEqualStrings("1 min 23 s", try duration(&buf, 83.2));
    try std.testing.expectEqualStrings("1 min", try duration(&buf, 60));
    try std.testing.expectEqualStrings("13 min", try duration(&buf, 800));
    try std.testing.expectEqualStrings("2 h 13 min", try duration(&buf, 8000));
}

test "explain puts the run's own numbers under each row" {
    var result = testResult();
    result.loss = null;
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try report(&w, result, null, .{ .color = false, .explain = true });
    const out = w.buffered();
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "under load\n    A 1 GB download takes 8.0 s; replies take 20.0 ms meanwhile (8.0 ms idle).\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "–\n    Pings are blocked here"));
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| try std.testing.expect(try std.unicode.utf8CountCodepoints(line) <= 80);
}

test "history reads back the runs this command records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    for ([_][]const u8{ "HOME", "LOCALAPPDATA", "XDG_STATE_HOME" }) |name| try environ.put(name, root);

    var result = testResult();
    result.gateway = .{ .wireless = true, .latency = result.latency };
    const entry = try std.json.Stringify.valueAlloc(std.testing.allocator, Json.of(&result), .{});
    defer std.testing.allocator.free(entry);
    const key: history.Key = .{ .asn = 3215, .wireless = true };
    for (0..3) |_| try std.testing.expectEqual(null, try history.record(std.testing.io, std.testing.allocator, &environ, key, entry));
    const usual = try history.record(std.testing.io, std.testing.allocator, &environ, key, entry);
    try std.testing.expectEqual(history.Rates{ .download = 1e9, .upload = 1e9 }, usual.?);
}
