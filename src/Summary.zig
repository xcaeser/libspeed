//! Nearest-rank percentiles of a sample set.
const Summary = @This();

const std = @import("std");

p10: f64 = 0,
p50: f64 = 0,
p90: f64 = 0,

/// Sorts `samples` in place.
pub fn of(samples: []f64) Summary {
    if (samples.len == 0) return .{};
    std.mem.sortUnstable(f64, samples, {}, std.sort.asc(f64));
    return .{
        .p10 = rank(samples, 10),
        .p50 = rank(samples, 50),
        .p90 = rank(samples, 90),
    };
}

fn rank(sorted: []const f64, percent: usize) f64 {
    const i = (sorted.len * percent + 99) / 100;
    return sorted[@max(i, 1) - 1];
}

/// Mean absolute difference between consecutive samples, in arrival order.
pub fn jitter(samples: []const f64) f64 {
    if (samples.len < 2) return 0;
    var sum: f64 = 0;
    for (samples[1..], samples[0 .. samples.len - 1]) |b, a| sum += @abs(b - a);
    return sum / @as(f64, @floatFromInt(samples.len - 1));
}

test of {
    var samples = [_]f64{ 10, 1, 9, 2, 8, 3, 7, 4, 6, 5 };
    const s = of(&samples);
    try std.testing.expectEqual(Summary{ .p10 = 1, .p50 = 5, .p90 = 9 }, s);
    try std.testing.expectEqual(Summary{}, of(&.{}));
}

test jitter {
    try std.testing.expectEqual(@as(f64, 2), jitter(&.{ 10, 12, 10, 12 }));
    try std.testing.expectEqual(@as(f64, 0), jitter(&.{5}));
}
