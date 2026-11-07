//! Who the test runs as, according to Cloudflare's `/meta`: the edge that
//! serves it and the network the request comes from.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The network a device reaches the internet through.
pub const Isp = struct {
    /// Autonomous system number.
    asn: u32,
    len: u8,
    buf: [63]u8,

    /// The operator's name, e.g. "Orange S.A.".
    pub fn name(isp: *const Isp) []const u8 {
        return isp.buf[0..isp.len];
    }
};

pub const Meta = struct {
    /// IATA code of the edge that served the request.
    colo: ?[3]u8,
    isp: ?Isp,
};

const none: Meta = .{ .colo = null, .isp = null };

/// Looks up the edge and network behind `host`. Identity is optional: anything
/// but a network error yields nulls. Throttling is detected by the load phases.
pub fn fetch(client: *std.http.Client, gpa: Allocator, host: []const u8) !Meta {
    const url = try std.fmt.allocPrint(gpa, "https://{s}/meta", .{host});
    defer gpa.free(url);
    var req = try client.request(.GET, try .parse(url), .{
        .redirect_behavior = .unhandled,
        // Read the body raw: `Client.fetch` panics on a body that is not in the
        // compression its headers claim.
        .headers = .{ .accept_encoding = .omit },
        // Cloudflare answers 403 unless the request looks like it comes from its own speed test page.
        .extra_headers = &.{.{ .name = "Origin", .value = "https://speed.cloudflare.com" }},
    });
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok or response.head.content_encoding != .identity) return none;
    var buf: [4096]u8 = undefined;
    const n = response.reader(&.{}).readSliceShort(&buf) catch {
        // A malformed body is the server's problem, not the connection's.
        if (response.bodyErr() != null) return none;
        return req.connection.?.getReadError().?;
    };
    // A body that fills `buf` is not the one this parses.
    if (n == buf.len) return none;
    return parse(gpa, buf[0..n]);
}

fn parse(gpa: Allocator, body: []const u8) Meta {
    const Body = struct {
        asn: ?u32 = null,
        asOrganization: ?[]const u8 = null,
        colo: ?struct { iata: ?[]const u8 = null } = null,
    };
    const parsed = std.json.parseFromSlice(Body, gpa, body, .{ .ignore_unknown_fields = true }) catch return none;
    defer parsed.deinit();
    const b = parsed.value;

    var meta = none;
    if (b.colo) |c| if (c.iata) |iata| if (iata.len == 3) {
        meta.colo = iata[0..3].*;
    };
    // AS 0 is reserved (RFC 7607) and means unknown across the C and TS APIs.
    if (b.asn) |asn| if (asn != 0) if (b.asOrganization) |org| {
        var isp: Isp = .{ .asn = asn, .len = 0, .buf = undefined };
        var n = @min(org.len, isp.buf.len);
        // Back up so a multi-byte codepoint is never cut in half.
        while (n > 0 and n < org.len and org[n] & 0xC0 == 0x80) n -= 1;
        // The name is printed to terminals: drop C0 and C1 controls. std.json
        // yields valid UTF-8, where C1 is 0xC2 followed by 0x80...0x9F.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = org[i];
            if (std.ascii.isControl(c)) continue;
            if (c == 0xC2 and i + 1 < n and org[i + 1] <= 0x9F) {
                i += 1;
                continue;
            }
            isp.buf[isp.len] = c;
            isp.len += 1;
        }
        if (isp.len > 0) meta.isp = isp;
    };
    return meta;
}

test "parse reads the edge and network from a real body" {
    const body =
        \\{"hostname":"speed.cloudflare.com","clientIp":"203.0.113.7","httpProtocol":"HTTP/1.1","asn":3215,"asOrganization":"Orange S.A.","country":"FR","city":"Asnières-sur-Seine","colo":{"iata":"CDG","lat":49.01,"lon":2.55,"cca2":"FR","region":"Europe","city":"Paris"}}
    ;
    const meta = parse(std.testing.allocator, body);
    try std.testing.expectEqualStrings("CDG", &meta.colo.?);
    try std.testing.expectEqual(3215, meta.isp.?.asn);
    try std.testing.expectEqualStrings("Orange S.A.", meta.isp.?.name());
}

test "parse of an empty answer knows nothing" {
    const meta = parse(std.testing.allocator, "{}");
    try std.testing.expectEqual(null, meta.colo);
    try std.testing.expectEqual(null, meta.isp);
}

test "parse truncates a long operator name on a codepoint boundary" {
    const body =
        \\{"asn":1,"asOrganization":"ééééééééééééééééééééééééééééééééééééééé"}
    ;
    const meta = parse(std.testing.allocator, body);
    const name = meta.isp.?.name();
    try std.testing.expect(name.len > 0 and name.len <= 63);
    try std.testing.expect(std.unicode.utf8ValidateSlice(name));
}

test "parse rejects AS 0 and strips control bytes from the name" {
    try std.testing.expectEqual(null, parse(std.testing.allocator, "{\"asn\":0,\"asOrganization\":\"X\"}").isp);
    const meta = parse(std.testing.allocator, "{\"asn\":7,\"asOrganization\":\"Evil\\u001b[2J\\u009b2JNét\"}");
    try std.testing.expectEqualStrings("Evil[2J2JNét", meta.isp.?.name());
}
