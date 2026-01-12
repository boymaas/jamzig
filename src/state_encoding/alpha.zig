const std = @import("std");
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const authorization_pool = @import("../authorizer_pool.zig");
const Alpha = authorization_pool.Alpha;

const trace = @import("tracing").scoped(.codec);

/// Encodes pools where each pool is length encoded. Length of pools is assumed to be C
pub fn encode(comptime core_count: u16, comptime max_pool_items: u8, self: *const Alpha(core_count, max_pool_items), writer: anytype) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting alpha encoding for {d} cores", .{core_count});

    for (self.pools, 0..) |pool, i| {
        const pool_span = span.child(@src(), .pool);
        defer pool_span.deinit();

        pool_span.debug("Encoding pool {d} of {d}", .{ i + 1, core_count });
        pool_span.trace("Pool length: {d}", .{pool.len});

        try codec.writeInteger(pool.len, writer);

        for (pool.slice(), 0..) |*auth, j| {
            const auth_span = pool_span.child(@src(), .auth);
            defer auth_span.deinit();
            auth_span.debug("Writing auth {d} of {d}", .{ j + 1, pool.len });
            auth_span.trace("Auth hash: {any}", .{std.fmt.fmtSliceHexLower(auth)});
            try writer.writeAll(auth);
        }
        pool_span.debug("Successfully encoded pool {d}", .{i + 1});
    }
    span.debug("Successfully encoded all {d} pools", .{core_count});
}

const testing = std.testing;

test "Alpha encode" {
    const C = 341;
    const O = 8;
    var alpha = Alpha(C, O).init();
    const core: usize = 0;
    const auth1: [32]u8 = [_]u8{1} ** 32;
    const auth2: [32]u8 = [_]u8{2} ** 32;

    try alpha.pools[core].append(auth1);
    try alpha.pools[core].append(auth2);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try encode(C, O, &alpha, buffer.writer());

    var expected = std.ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();
    try expected.appendSlice(encoder.encodeInteger(2).as_slice());
    try expected.appendSlice(&auth1);
    try expected.appendSlice(&auth2);
    for (1..C) |_| {
        try expected.appendSlice(encoder.encodeInteger(0).as_slice());
    }

    try testing.expectEqualSlices(u8, expected.items, buffer.items);
}
