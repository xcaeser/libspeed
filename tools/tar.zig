//! `tar OUT [NAME PATH]...` writes a gzipped tarball with each file at PATH
//! stored as NAME, keeping its permissions. Each parent directory gets an entry
//! before its first file.
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len % 2 != 0) return error.Usage;

    const out = try Io.Dir.cwd().createFile(io, args[1], .{});
    defer out.close(io);
    var out_buf: [64 << 10]u8 = undefined;
    var out_writer = out.writer(io, &out_buf);
    var window: [flate.max_window_len]u8 = undefined;
    var gzip: flate.Compress = try .init(&out_writer.interface, &window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };

    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    var pairs = std.mem.window([:0]const u8, args[2..], 2, 2);
    while (pairs.next()) |pair| {
        const name, const path = pair[0..2].*;
        if (std.fs.path.dirnamePosix(name)) |dir| {
            if (!(try dirs.getOrPut(init.arena.allocator(), dir)).found_existing) try tar.writeDir(dir, .{ .mode = 0o755 });
        }
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        var buf: [64 << 10]u8 = undefined;
        var reader = file.reader(io, &buf);
        try tar.writeFileStream(name, stat.size, &reader.interface, .{ .mode = @backingInt(stat.permissions) & 0o777 });
    }
    try tar.finishPedantically();
    try gzip.finish();
    try out_writer.interface.flush();
}
