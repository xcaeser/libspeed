const std = @import("std");
const Io = std.Io;
const zli = @import("zli");

const run = @import("cli/run.zig");
const upgrade = @import("cli/upgrade.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var wbuf: [4096]u8 = undefined;
    var stdout = Io.File.Writer.init(.stdout(), io, &wbuf);
    var rbuf: [64]u8 = undefined;
    var stdin = Io.File.Reader.init(.stdin(), io, &rbuf);

    const options: zli.InitOptions = .{
        .allocator = init.gpa,
        .io = io,
        .writer = &stdout.interface,
        .reader = &stdin.interface,
    };

    const root = try zli.Command.init(options, .{
        .name = "speed",
        .description = "Measure your internet connection: speed, latency, jitter and packet loss.",
        .version = @import("build_options").version,
    }, help);
    try root.addFlag(.{
        .name = "version",
        .shortcut = "v",
        .description = "Print the version",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try root.addCommands(&.{
        try run.command(options),
        try zli.Command.init(options, .{ .name = "version", .description = "Print the version" }, version),
        try upgrade.command(options),
    });

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    root.runAndExit(&args, .{});
}

fn help(ctx: zli.CommandContext) !void {
    if (ctx.flag("version", bool)) return version(ctx);
    try ctx.command.printHelp();
}

fn version(ctx: zli.CommandContext) !void {
    try ctx.root.printVersion();
}

test {
    _ = run;
    _ = upgrade;
}
