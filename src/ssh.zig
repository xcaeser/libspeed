//! Streams over the user's own `ssh`: zeros from `cat /dev/zero` down, into
//! `cat >/dev/null` up. Nothing is installed or left running on the host.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

const Direction = @import("load.zig").Direction;
const probe = @import("probe.zig");

/// Zeros compress to nothing, so compression would report rates the link
/// never carried. Without a control master each stream is its own TCP flow.
/// The rest keeps a host's config from replacing `cat` or failing the session
/// over a forward, and ends a session whose host stops answering.
const options = [_][]const u8{
    "-T",                        "-oBatchMode=yes",         "-oCompression=no", "-oControlMaster=no",
    "-oControlPath=none",        "-oConnectTimeout=10",     "-oLogLevel=ERROR", "-oRemoteCommand=none",
    "-oClearAllForwardings=yes", "-oPermitLocalCommand=no", "-oForwardX11=no",  "-oForwardAgent=no",
    "-oServerAliveInterval=5",   "-oServerAliveCountMax=3",
};

/// The address `ssh` connects to for `destination`, after ~/.ssh/config, for
/// ICMP. Null when unknown, or when ssh reaches the host through a proxy and
/// the address may mean something else from here.
pub fn address(io: Io, gpa: Allocator, destination: []const u8) Io.Cancelable!?net.IpAddress {
    return lookup(io, gpa, destination) catch |err| switch (err) {
        error.Canceled => |e| e,
        else => null,
    };
}

fn lookup(io: Io, gpa: Allocator, destination: []const u8) !?net.IpAddress {
    const result = try std.process.run(gpa, io, .{
        .argv = &[_][]const u8{ "ssh", "-G" } ++ options ++ .{ "--", destination },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return null;
    const host, const port = try endpoint(result.stdout) orelse return null;
    if (net.IpAddress.parse(host, port)) |a| return a else |_| {}
    return (try probe.resolve(io, host, port)).address;
}

/// The hostname and port in `ssh -G` output, or null through a proxy.
fn endpoint(config: []const u8) !?struct { []const u8, u16 } {
    var host: ?[]const u8 = null;
    var port: u16 = 22;
    var lines = std.mem.tokenizeScalar(u8, config, '\n');
    while (lines.next()) |line| {
        const space = std.mem.findScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = std.mem.trim(u8, line[space + 1 ..], " \r");
        if (std.mem.eql(u8, key, "hostname")) host = value;
        if (std.mem.eql(u8, key, "port")) port = try std.fmt.parseInt(u16, value, 10);
        if (std.mem.eql(u8, key, "proxyjump") or std.mem.eql(u8, key, "proxycommand")) return null;
    }
    return .{ host orelse return null, port };
}

/// Round trips of one byte through `cat` in a logged-in session. TCP
/// handshakes would not do: OpenSSH 9.8+ refuses an address for a while after
/// connections that never try to log in.
pub const Echo = struct {
    child: std.process.Child,
    /// Each echo sends the next value; bytes still in flight from an echo that
    /// was canceled or timed out are skipped.
    seq: u8 = 0,

    /// Logs in and makes one round trip, so a refused login fails before any
    /// phase runs and login time stays out of the samples. ssh says why on stderr.
    pub fn open(io: Io, destination: []const u8) !Echo {
        var e: Echo = .{ .child = try std.process.spawn(io, .{
            .argv = &[_][]const u8{"ssh"} ++ options ++ .{ "--", destination, "cat" },
            .stdin = .pipe,
            .stdout = .pipe,
        }) };
        errdefer e.close(io);
        _ = e.ms(io) catch return error.SshFailed;
        return e;
    }

    pub fn close(e: *Echo, io: Io) void {
        e.child.kill(io);
    }

    pub fn ms(e: *Echo, io: Io) !f64 {
        e.seq +%= 1;
        var byte: [1]u8 = .{e.seq};
        const start = Io.Clock.awake.now(io);
        var writer = e.child.stdin.?.writerStreaming(io, &.{});
        try writer.interface.writeAll(&byte);
        var reader = e.child.stdout.?.readerStreaming(io, &.{});
        while (true) {
            try reader.interface.readSliceAll(&byte);
            if (byte[0] == e.seq) return probe.ms(start.untilNow(io, .awake));
        }
    }
};

/// A stream of zeros: read the child's stdout to download, write its stdin to
/// upload. Kill the child to end it.
pub fn spawn(io: Io, destination: []const u8, direction: Direction) !std.process.Child {
    const command = switch (direction) {
        .download => "cat /dev/zero",
        .upload => "cat >/dev/null",
    };
    return std.process.spawn(io, .{
        .argv = &[_][]const u8{"ssh"} ++ options ++ .{ "--", destination, command },
        .stdin = if (direction == .upload) .pipe else .ignore,
        .stdout = if (direction == .download) .pipe else .ignore,
        .stderr = .ignore,
    });
}

test endpoint {
    const host, const port = (try endpoint("user me\nhostname 2001:db8::7\nport 2222\nidentityfile ~/.ssh/id_ed25519\n")).?;
    try std.testing.expectEqualStrings("2001:db8::7", host);
    try std.testing.expectEqual(2222, port);
    try std.testing.expectEqual(null, try endpoint("hostname 10.0.0.7\nproxyjump bastion\n"));
    try std.testing.expectEqual(null, try endpoint("port 22\n"));
}
