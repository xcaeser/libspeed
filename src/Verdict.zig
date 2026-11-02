//! Which side of the router makes a connection feel slow: the local network
//! (Wi-Fi, cabling, the router itself) or the ISP's line beyond it. Compares
//! round trips to the edge, which cross both, with round trips to the gateway,
//! which cross only the local network.
const Verdict = @This();

const std = @import("std");
const Load = @import("load.zig").Result;
const Phase = @import("root.zig").Phase;

segment: Segment,
/// `.latency` when the segment slows every request; otherwise the direction
/// whose traffic fills its queue.
phase: Phase,
/// Round trip the segment adds, in ms.
added: f64,

pub const Segment = enum(u8) { local, isp };

/// Waveform's bufferbloat test grades below A from +30 ms under load, about
/// where calls and games start to lag.
const noticeable_load = 30;
/// Assumed: Wi-Fi to a nearby router answers in a few ms, so 10 ms idle means
/// a weak or crowded link.
const noticeable_local = 10;

/// `latency` and `gateway` are idle round trips to the edge and the gateway,
/// in ms. Null when nothing noticeable slows the connection, or when the
/// gateway went silent under the load that slowed it.
pub fn of(latency: f64, gateway: f64, download: Load, upload: Load) ?Verdict {
    const phase: Phase, const busy = if (upload.latency.p50 > download.latency.p50) .{ .upload, upload } else .{ .download, download };
    const added = busy.latency.p50 - latency;
    if (added >= noticeable_load) {
        const local = std.math.clamp((busy.gateway_latency orelse return null).p50 - gateway, 0, added);
        return if (local * 2 >= added)
            .{ .segment = .local, .phase = phase, .added = local }
        else
            .{ .segment = .isp, .phase = phase, .added = added - local };
    }
    if (gateway >= noticeable_local and gateway * 2 >= latency) return .{ .segment = .local, .phase = .latency, .added = gateway };
    return null;
}

fn load(edge: f64, gateway: ?f64) Load {
    return .{
        .bps = .{},
        .latency = .{ .p50 = edge },
        .gateway_latency = if (gateway) |g| .{ .p50 = g } else null,
    };
}

test of {
    const expectEqual = std.testing.expectEqual;
    // Healthy: little added anywhere.
    try expectEqual(null, of(8, 4, load(28, 8), load(20, 6)));
    // Uploads fill the Wi-Fi queue: the gateway's round trip grows with the edge's.
    try expectEqual(Verdict{ .segment = .local, .phase = .upload, .added = 76 }, of(8, 4, load(20, 6), load(100, 80)));
    // Downloads fill the modem's queue: the gateway stays quick.
    try expectEqual(Verdict{ .segment = .isp, .phase = .download, .added = 112 }, of(10, 2, load(130, 10), load(20, 3)));
    // A slow gateway on an idle link.
    try expectEqual(Verdict{ .segment = .local, .phase = .latency, .added = 15 }, of(22, 15, load(30, 18), load(25, 16)));
    // Slow overall but far away, not local.
    try expectEqual(null, of(80, 12, load(90, 14), load(85, 13)));
    // Bloated, but the gateway never answered under load.
    try expectEqual(null, of(8, 4, load(20, 6), load(100, null)));
}
