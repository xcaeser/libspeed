const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const speed = @import("speed");
const run = @import("run.zig");

pub fn command(options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(options, .{
        .name = "to",
        .description = "Test the link to a host you can ssh into",
    }, exec);
    try cmd.addPositionalArg(.{
        .name = "destination",
        .description = "As ssh takes it: an alias from ~/.ssh/config, user@host, or ssh://user@host:port",
        .required = true,
    });
    return cmd;
}

fn exec(ctx: zli.CommandContext) !void {
    const w = ctx.writer;
    const destination = ctx.getArg("destination").?;
    const tty = try Io.File.stdout().isTty(ctx.io);

    var live: run.Live = .{ .w = w };
    var options: speed.Options = .{ .target = .{ .ssh = destination } };
    if (tty) options.listener = .{ .context = &live, .onEvent = run.Live.onEvent };

    const result = speed.run(ctx.io, ctx.allocator, options) catch |err| {
        if (tty) try w.writeAll(run.clear_line);
        switch (err) {
            // ssh has already said why on stderr.
            error.SshFailed => try w.print("Could not log in to {s} with ssh.\n", .{destination}),
            error.ReadFailed, error.WriteFailed, error.EndOfStream => try w.print("Lost the ssh session to {s}.\n", .{destination}),
            error.FileNotFound => try w.writeAll("speed to needs ssh, which is not installed.\n"),
            error.NoThroughput => try w.print("Nothing came through ssh from {s}; it needs cat and /dev/zero.\n", .{destination}),
            else => return err,
        }
        try w.flush();
        std.process.exit(1);
    };
    if (tty) try w.writeAll(run.clear_line);
    try run.report(w, result, null, .{ .color = tty, .explain = false });
}
