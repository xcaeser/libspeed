const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zli = @import("zli");

const current = @import("build_options").version;
const repo = "xcaeser/libspeed";

/// Matches the release assets .github/workflows/release.yml uploads.
const asset = std.fmt.comptimePrint("speed-{s}-{s}{s}", .{
    switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    },
    switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @tagName(builtin.cpu.arch),
    },
    builtin.os.tag.exeFileExt(builtin.cpu.arch),
});

pub fn command(options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(options, .{
        .name = "upgrade",
        .description = "Replace this binary with the latest GitHub release",
    }, exec);
}

const Release = struct {
    tag_name: []const u8,
    assets: []const struct {
        name: []const u8,
        browser_download_url: []const u8,
        /// "sha256:<hex>", computed by GitHub on upload.
        digest: ?[]const u8 = null,
    },
};

fn exec(ctx: zli.CommandContext) !void {
    const io, const gpa, const w = .{ ctx.io, ctx.allocator, ctx.writer };

    const self_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_path);
    // npm owns files under node_modules and would put the old version back.
    if (std.mem.find(u8, self_path, "node_modules") != null) {
        return w.writeAll("speed was installed with npm. Upgrade it with:\n  npm install -g @xcaeser/speed@latest\n");
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest" },
        .response_writer = &body.writer,
        .extra_headers = &.{.{ .name = "accept", .value = "application/vnd.github+json" }},
    });
    switch (res.status) {
        .ok => {},
        .not_found => return w.writeAll("No release of speed has been published yet.\n"),
        else => return error.GitHubUnavailable,
    }

    const parsed = try std.json.parseFromSlice(Release, gpa, body.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const release = parsed.value;
    const latest = try std.SemanticVersion.parse(std.mem.trimStart(u8, release.tag_name, "v"));

    if (latest.order(current) != .gt) return w.print("speed {f} is the latest version.\n", .{current});

    const found = for (release.assets) |a| {
        if (std.mem.eql(u8, a.name, asset)) break a;
    } else return w.print("speed {f} has no build for this platform ({s}).\n", .{ latest, asset });
    const digest = found.digest orelse return error.MissingChecksum;

    try w.print("Downloading speed {f}…\n", .{latest});
    try w.flush();
    body.clearRetainingCapacity();
    try download(&client, found.browser_download_url, &body.writer);
    try verify(body.written(), digest);

    try replace(io, gpa, self_path, body.written());
    try w.print("Upgraded speed {f} → {f}\n", .{ current, latest });
}

/// Like `client.fetch`, which asserts on a dropped connection mid-body.
fn download(client: *std.http.Client, url: []const u8, out: *Io.Writer) !void {
    var req = try client.request(.GET, try .parse(url), .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect: [8 << 10]u8 = undefined;
    var response = try req.receiveHead(&redirect);
    if (response.head.status != .ok) return error.DownloadFailed;
    _ = response.reader(&.{}).streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse req.connection.?.getReadError().?,
        error.WriteFailed => return error.OutOfMemory,
    };
}

fn verify(bytes: []const u8, digest: []const u8) !void {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return error.MissingChecksum;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, digest[prefix.len..]) catch return error.MissingChecksum;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &expected, &actual)) return error.ChecksumMismatch;
}

/// Writes next to the running binary, then renames over it so a failure
/// never leaves a half-written `speed`.
fn replace(io: Io, gpa: std.mem.Allocator, self_path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const staged = try std.fmt.allocPrint(gpa, "{s}.new", .{self_path});
    defer gpa.free(staged);
    try cwd.writeFile(io, .{
        .sub_path = staged,
        .data = bytes,
        .flags = .{ .permissions = .executable_file },
    });
    errdefer cwd.deleteFile(io, staged) catch {};

    if (builtin.os.tag != .windows) return cwd.rename(staged, cwd, self_path, io);

    // Windows cannot overwrite a running executable, but can rename it.
    const old = try std.fmt.allocPrint(gpa, "{s}.old", .{self_path});
    defer gpa.free(old);
    cwd.deleteFile(io, old) catch {};
    try cwd.rename(self_path, cwd, old, io);
    errdefer cwd.rename(old, cwd, self_path, io) catch {};
    try cwd.rename(staged, cwd, self_path, io);
}

test verify {
    const digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try verify("hello", digest);
    try std.testing.expectError(error.ChecksumMismatch, verify("hellO", digest));
    try std.testing.expectError(error.MissingChecksum, verify("hello", "md5:abc"));
}
