//! Local history of runs, so a run can be compared with what is usual on
//! this connection.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Summary = @import("speed").Summary;

/// Runs compare only with runs on the same network and link.
pub const Key = struct { asn: u32, wireless: ?bool };
/// Median download and upload p50, in bits per second.
pub const Rates = struct { download: f64, upload: f64 };

const min_runs = 3;
const max_runs = 20;
// ponytail: reads at most the last 16 MiB (~25k runs); older runs are ignored
// and never trimmed from the file. Rotate the file if that ever matters.
const max_read = 16 << 20;

/// Appends `entry` (one JSON object, no trailing newline) to the history file,
/// and returns the median rates of the last 20 earlier runs with the same key,
/// or null with fewer than 3 such runs or without a key.
pub fn record(io: Io, gpa: Allocator, environ: *const std.process.Environ.Map, key: ?Key, entry: []const u8) !?Rates {
    const file_path = try path(gpa, environ);
    defer gpa.free(file_path);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, Io.Dir.path.dirname(file_path).?);

    // The Io API has no O_APPEND; an exclusive lock keeps concurrent runs
    // from writing over each other's line instead.
    var file = try cwd.createFile(io, file_path, .{ .read = true, .truncate = false, .lock = .exclusive });
    defer file.close(io);

    const len = try file.length(io);
    const start = len -| max_read;
    const buf = try gpa.alloc(u8, len - start);
    defer gpa.free(buf);
    var history = buf[0..try file.readPositionalAll(io, buf, start)];
    // A crash can leave a last line without its newline: start a fresh line.
    const lead: []const u8 = if (history.len > 0 and history[history.len - 1] != '\n') "\n" else "";
    // Reading from the middle of a line: drop the partial one.
    if (start > 0) history = history[if (std.mem.findScalar(u8, history, '\n')) |i| i + 1 else history.len..];

    const line = try std.mem.concat(gpa, u8, &.{ lead, entry, "\n" });
    defer gpa.free(line);
    try file.writePositionalAll(io, line, len);

    return usual(gpa, history, key orelse return null);
}

/// A line of the history; everything else in it is ignored.
const Line = struct {
    isp: ?struct { asn: u32 },
    gateway: ?struct { wireless: bool },
    download: struct { bps: struct { p50: f64 } },
    upload: struct { bps: struct { p50: f64 } },
};

fn usual(gpa: Allocator, history: []const u8, key: Key) !?Rates {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var download: std.ArrayList(f64) = .empty;
    var upload: std.ArrayList(f64) = .empty;
    var lines = std.mem.splitScalar(u8, history, '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, arena.allocator(), text, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const isp = line.isp orelse continue;
        if (isp.asn != key.asn) continue;
        if (key.wireless != if (line.gateway) |g| g.wireless else null) continue;
        try download.append(arena.allocator(), line.download.bps.p50);
        try upload.append(arena.allocator(), line.upload.bps.p50);
    }

    if (download.items.len < min_runs) return null;
    const from = download.items.len -| max_runs;
    return .{
        .download = Summary.of(download.items[from..]).p50,
        .upload = Summary.of(upload.items[from..]).p50,
    };
}

fn path(gpa: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const parts: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ dir(environ, "HOME") orelse return error.NoHomeDirectory, "Library", "Application Support", "speed", "history.jsonl" },
        .windows => &.{ dir(environ, "LOCALAPPDATA") orelse return error.NoHomeDirectory, "speed", "history.jsonl" },
        else => if (dir(environ, "XDG_STATE_HOME")) |state|
            &.{ state, "speed", "history.jsonl" }
        else
            &.{ dir(environ, "HOME") orelse return error.NoHomeDirectory, ".local", "state", "speed", "history.jsonl" },
    };
    return Io.Dir.path.join(gpa, parts);
}

/// The variable's value when it is an absolute path; empty or relative values
/// would put the history in whatever directory speed runs from.
fn dir(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = environ.get(name) orelse return null;
    return if (Io.Dir.path.isAbsolute(value)) value else null;
}

fn run(comptime asn: u32, comptime wireless: []const u8, comptime download: u32) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"isp":{{"asn":{d},"name":"x"}},"gateway":{{"wireless":{s}}},"download":{{"bps":{{"p50":{d}}}}},"upload":{{"bps":{{"p50":{d}}}}}}}
        \\
    , .{ asn, wireless, download, download / 10 });
}

fn repeat(comptime n: usize, comptime line: []const u8) []const u8 {
    var out: []const u8 = "";
    for (0..n) |_| out = out ++ line;
    return out;
}

test "usual takes the median of matching runs only" {
    const history = comptime run(3215, "true", 100) ++ run(9999, "true", 7) ++ run(3215, "false", 5) ++
        "{\"isp\":{\"asn\":3215},\"download\":{\"bps\":{\"p5\n" ++
        \\{"isp":null,"gateway":null,"download":{"bps":{"p50":1}},"upload":{"bps":{"p50":1}}}
        \\
    ++ run(3215, "true", 300) ++ run(3215, "true", 200);
    const rates = (try usual(std.testing.allocator, history, .{ .asn = 3215, .wireless = true })).?;
    try std.testing.expectEqual(Rates{ .download = 200, .upload = 20 }, rates);
}

test "usual needs three matching runs" {
    const history = comptime run(3215, "true", 100) ++ run(3215, "true", 200) ++ run(3215, "false", 300);
    try std.testing.expectEqual(null, try usual(std.testing.allocator, history, .{ .asn = 3215, .wireless = true }));
    try std.testing.expectEqual(null, try usual(std.testing.allocator, "", .{ .asn = 3215, .wireless = null }));
}

test "usual counts only the last 20 matching runs" {
    const history = comptime repeat(10, run(1, "true", 1000)) ++ repeat(20, run(1, "true", 10));
    const rates = (try usual(std.testing.allocator, history, .{ .asn = 1, .wireless = true })).?;
    try std.testing.expectEqual(10, rates.download);
}

test "record appends and compares with earlier runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", root);
    try environ.put("LOCALAPPDATA", root);
    try environ.put("XDG_STATE_HOME", root);

    const key: Key = .{ .asn = 3215, .wireless = true };
    const entries = [_][]const u8{ run(3215, "true", 100), run(3215, "true", 300), run(3215, "true", 200), run(3215, "true", 900) };
    for (entries[0..3]) |entry| {
        try std.testing.expectEqual(null, try record(std.testing.io, std.testing.allocator, &environ, key, std.mem.trimEnd(u8, entry, "\n")));
    }
    const rates = try record(std.testing.io, std.testing.allocator, &environ, key, std.mem.trimEnd(u8, entries[3], "\n"));
    try std.testing.expectEqual(Rates{ .download = 200, .upload = 20 }, rates.?);

    const file_path = try path(std.testing.allocator, &environ);
    defer std.testing.allocator.free(file_path);
    const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(4, std.mem.count(u8, text, "\n"));
}

test "record without an absolute home directory fails" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expectError(error.NoHomeDirectory, record(std.testing.io, std.testing.allocator, &environ, null, "{}"));
    for ([_][]const u8{ "HOME", "LOCALAPPDATA", "XDG_STATE_HOME" }) |name| try environ.put(name, "");
    try std.testing.expectError(error.NoHomeDirectory, record(std.testing.io, std.testing.allocator, &environ, null, "{}"));
}

test "record starts a fresh line after a line cut short" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    for ([_][]const u8{ "HOME", "LOCALAPPDATA", "XDG_STATE_HOME" }) |name| try environ.put(name, root);

    _ = try record(std.testing.io, std.testing.allocator, &environ, null, "{\"a\":1}");
    const file_path = try path(std.testing.allocator, &environ);
    defer std.testing.allocator.free(file_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = "{\"isp\":{\"as" });
    _ = try record(std.testing.io, std.testing.allocator, &environ, null, "{\"a\":2}");

    const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"isp\":{\"as\n{\"a\":2}\n", text);
}
