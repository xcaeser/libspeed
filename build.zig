const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug info (default in release builds)") orelse (optimize != .debug);

    const mod = b.addModule("speed", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable);

    const zli = b.dependency("zli", .{ .target = target, .optimize = optimize }).module("zli");
    const exe = b.addExecutable(.{
        .name = "speed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "speed", .module = mod },
                .{ .name = "zli", .module = zli },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    // libspeed.a for static linking (Go, Swift, C), libspeed.dylib/.so for bun:ffi.
    // ponytail: Windows gets the DLL only, its import library would overwrite
    // speed.lib; name the static one apart if a Windows static consumer appears.
    const linkages: []const std.builtin.LinkMode = if (target.result.os.tag == .windows) &.{.dynamic} else &.{ .static, .dynamic };
    for (linkages) |linkage| {
        const lib = b.addLibrary(.{
            .name = "speed",
            .linkage = linkage,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/c.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                // Host threads need the host's libc: without it, std sets up
                // thread-local storage from state only an executable's start
                // code initializes.
                .link_libc = true,
            }),
        });
        lib.installHeader(b.path("include/speed.h"), "speed.h");
        b.installArtifact(lib);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}
