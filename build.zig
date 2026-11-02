const std = @import("std");
const Build = std.Build;

const version = @import("build.zig.zon").version;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug info (default in release builds)") orelse (optimize != .debug);

    const mod = b.addModule("speed", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    const libs = libraries(b, target, optimize, strip);
    if (libs.static) |lib| b.installArtifact(lib);
    b.installArtifact(libs.dynamic);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // The CLI builds only at the top level, so packages importing the `speed`
    // module never fetch its lazy zli dependency.
    if (b.dep_prefix.len != 0) return;
    const exe = cli(b, mod, target, optimize, strip) orelse return;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    release(b);
}

const Libraries = struct {
    /// libspeed.a for static linking (Go, Swift, C); null on Windows.
    static: ?*Build.Step.Compile,
    /// libspeed.dylib/.so or speed.dll, for bun:ffi.
    dynamic: *Build.Step.Compile,
};

fn libraries(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool) Libraries {
    const lib = struct {
        fn add(owner: *Build, t: Build.ResolvedTarget, o: std.builtin.OptimizeMode, s: bool, linkage: std.builtin.LinkMode) *Build.Step.Compile {
            const l = owner.addLibrary(.{
                .name = "speed",
                .linkage = linkage,
                .root_module = owner.createModule(.{
                    .root_source_file = owner.path("src/c.zig"),
                    .target = t,
                    .optimize = o,
                    .strip = s,
                    // Host threads need the host's libc: without it, std sets up
                    // thread-local storage from state only an executable's start
                    // code initializes.
                    .link_libc = true,
                }),
            });
            l.installHeader(owner.path("include/speed.h"), "speed.h");
            return l;
        }
    };
    // ponytail: Windows gets the DLL only, its import library would overwrite
    // speed.lib; name the static one apart if a Windows static consumer appears.
    const windows = target.result.os.tag == .windows;
    return .{
        .static = if (windows) null else lib.add(b, target, optimize, strip, .static),
        .dynamic = lib.add(b, target, optimize, strip, .dynamic),
    };
}

/// Null until the lazy zli dependency is fetched.
fn cli(b: *Build, mod: *Build.Module, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool) ?*Build.Step.Compile {
    const zli = b.lazyDependency("zli", .{ .target = target, .optimize = optimize }) orelse return null;
    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(version) catch unreachable);
    return b.addExecutable(.{
        .name = "speed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "speed", .module = mod },
                .{ .name = "zli", .module = zli.module("zli") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
}

/// npm platform name and Zig target.
const platforms = [_]struct { []const u8, []const u8 }{
    .{ "darwin-arm64", "aarch64-macos" },
    .{ "darwin-x64", "x86_64-macos" },
    // glibc so libspeed.so loads into ordinary hosts; the CLI links no libc and stays static.
    .{ "linux-arm64", "aarch64-linux-gnu.2.28" },
    .{ "linux-x64", "x86_64-linux-gnu.2.28" },
    .{ "win32-arm64", "aarch64-windows" },
    .{ "win32-x64", "x86_64-windows" },
};

/// Cross-compiles every platform into GitHub release assets (zig-out/release:
/// raw binaries, static libraries, SDK tarballs, Linux .deb/.rpm) and npm
/// packages (zig-out/npm/<platform>, and zig-out/npm/speed last).
fn release(b: *Build) void {
    const step = b.step("release", "Package every platform for GitHub and npm");
    const tar = b.addExecutable(.{
        .name = "tar",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/tar.zig"), .target = b.graph.host }),
    });

    const template_path = b.root.join(b.allocator, "npm/package.json") catch @panic("OOM");
    const template = template_path.root_dir.handle.readFileAlloc(b.graph.io, template_path.sub_path, b.allocator, .limited(1 << 20)) catch |err|
        std.debug.panic("npm/package.json: {t}", .{err});
    var main = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, template, .{}) catch |err|
        std.debug.panic("npm/package.json: {t}", .{err});
    var dependencies: std.json.ObjectMap = .empty;

    for (platforms) |platform| {
        const name, const triple = platform;
        const os, const cpu = blk: {
            var it = std.mem.splitScalar(u8, name, '-');
            break :blk .{ it.next().?, it.next().? };
        };
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        const mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .ReleaseSmall, .strip = true });
        const libs = libraries(b, target, .ReleaseSmall, true);
        const exe = (cli(b, mod, target, .ReleaseSmall, true) orelse return).getEmittedBin();
        const windows = target.result.os.tag == .windows;
        const exe_name = if (windows) "speed.exe" else "speed";
        const shared_name = switch (target.result.os.tag) {
            .windows => "speed.dll",
            .macos => "libspeed.dylib",
            else => "libspeed.so",
        };

        // `speed upgrade` looks for exactly these names.
        install(step, exe, "release", b.fmt("speed-{s}{s}", .{ name, if (windows) ".exe" else "" }));
        if (libs.static) |lib| install(step, lib.getEmittedBin(), "release", b.fmt("libspeed-{s}.a", .{name}));

        // An install prefix, which is what `mise use github:xcaeser/libspeed`
        // unpacks. Shared libraries keep their names: the dylib's install name
        // and the .so's soname are what loaders look for.
        const tarball = b.addRunArtifact(tar);
        const tarball_name = b.fmt("libspeed-{s}.tar.gz", .{name});
        const tarball_out = tarball.addOutputFileArg(tarball_name);
        tarball.addArg(b.fmt("bin/{s}", .{exe_name}));
        tarball.addFileArg(exe);
        if (windows) {
            tarball.addArg("bin/speed.dll");
            tarball.addFileArg(libs.dynamic.getEmittedBin());
            tarball.addArg("lib/speed.lib");
            tarball.addFileArg(libs.dynamic.getEmittedImplib());
        } else {
            tarball.addArg("lib/libspeed.a");
            tarball.addFileArg(libs.static.?.getEmittedBin());
            tarball.addArg(b.fmt("lib/{s}", .{shared_name}));
            tarball.addFileArg(libs.dynamic.getEmittedBin());
        }
        tarball.addArg("include/speed.h");
        tarball.addFileArg(b.path("include/speed.h"));
        install(step, tarball_out, "release", tarball_name);

        const package_name = b.fmt("@xcaeser/speed-{s}", .{name});
        const dir = b.fmt("npm/{s}", .{name});
        install(step, exe, dir, exe_name);
        install(step, libs.dynamic.getEmittedBin(), dir, shared_name);
        install(step, b.path("LICENSE"), dir, "LICENSE");
        install(step, b.addWriteFiles().add("package.json", json(b, .{
            .name = package_name,
            .version = version,
            .description = b.fmt("speed binary and libspeed for {s}", .{name}),
            .license = main.object.get("license").?.string,
            .repository = main.object.get("repository").?.string,
            .os = &[_][]const u8{os},
            .cpu = &[_][]const u8{cpu},
        })), dir, "package.json");
        dependencies.put(b.allocator, package_name, .{ .string = version }) catch @panic("OOM");

        if (target.result.os.tag == .linux) linuxPackages(b, step, exe, cpu, main.object.get("description").?.string);
    }
    install(step, b.path("include/speed.h"), "release", "speed.h");

    main.object.put(b.allocator, "version", .{ .string = version }) catch @panic("OOM");
    main.object.put(b.allocator, "optionalDependencies", .{ .object = dependencies }) catch @panic("OOM");
    install(step, b.addWriteFiles().add("package.json", json(b, main)), "npm/speed", "package.json");
    for ([_][]const u8{ "index.ts", "worker.ts", "bin/speed.js" }) |file| install(step, b.path(b.fmt("npm/{s}", .{file})), "npm/speed", file);
    // npm only packs these from the package's own directory.
    for ([_][]const u8{ "LICENSE", "README.md" }) |file| install(step, b.path(file), "npm/speed", file);
}

fn linuxPackages(b: *Build, step: *Build.Step, exe: Build.LazyPath, cpu: []const u8, description: []const u8) void {
    const deb_arch, const rpm_arch = if (std.mem.eql(u8, cpu, "x64")) .{ "amd64", "x86_64" } else .{ "arm64", "aarch64" };
    // nfpm resolves `src` against its working directory.
    const files = b.addWriteFiles();
    _ = files.addCopyFile(exe, "speed");
    _ = files.addCopyFile(b.path("LICENSE"), "LICENSE");
    _ = files.add("nfpm.yaml", b.fmt(
        \\name: speed
        \\arch: {s}
        \\platform: linux
        \\version: {s}
        \\maintainer: xcaeser
        \\description: {f}
        \\homepage: https://github.com/xcaeser/libspeed
        \\license: MIT
        \\contents:
        \\  - src: speed
        \\    dst: /usr/bin/speed
        \\    file_info:
        \\      mode: 0755
        \\  - src: LICENSE
        \\    dst: /usr/share/doc/speed/copyright
        \\
    , .{ deb_arch, version, std.json.fmt(description, .{}) }));
    for ([_]struct { []const u8, []const u8 }{
        .{ "deb", b.fmt("speed_{s}_{s}.deb", .{ version, deb_arch }) },
        .{ "rpm", b.fmt("speed-{s}-1.{s}.rpm", .{ version, rpm_arch }) },
    }) |package| {
        const packager, const file = package;
        const nfpm = b.addSystemCommand(&.{ "nfpm", "package", "--config", "nfpm.yaml", "--packager", packager, "--target" });
        nfpm.setCwd(files.getDirectory());
        install(step, nfpm.addOutputFileArg(file), "release", file);
    }
}

fn install(step: *Build.Step, source: Build.LazyPath, dir: []const u8, name: []const u8) void {
    step.dependOn(&step.owner.addInstallFileWithDir(source, .{ .custom = dir }, name).step);
}

fn json(b: *Build, value: anytype) []const u8 {
    const text = std.json.Stringify.valueAlloc(b.allocator, value, .{ .whitespace = .indent_2 }) catch @panic("OOM");
    return b.fmt("{s}\n", .{text});
}
