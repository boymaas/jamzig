const std = @import("std");
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const authorization = @import("../authorization.zig");
const Alpha = authorization.Alpha;

const trace = @import("../tracing.zig").scoped(.codec);

/// Encodes pools where each pool is length encoded. Length of pools is assumed to be C
pub fn encode(comptime core_count: u16, self: *const Alpha(core_count), writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting alpha encoding for {d} cores", .{core_count});

    // Encode pools
    for (self.pools, 0..) |pool, i| {
        const pool_span = span.child(.pool);
        defer pool_span.deinit();

        pool_span.debug("Encoding pool {d} of {d}", .{ i + 1, core_count });
        pool_span.trace("Pool length: {d}", .{pool.len});

        try codec.writeInteger(pool.len, writer);

        for (pool.slice(), 0..) |*auth, j| {
            const auth_span = pool_span.child(.auth);
            defer auth_span.deinit();
            auth_span.debug("Writing auth {d} of {d}", .{ j + 1, pool.len });
            auth_span.trace("Auth hash: {any}", .{std.fmt.fmtSliceHexLower(auth)});
            try writer.writeAll(auth);
        }
        pool_span.debug("Successfully encoded pool {d}", .{i + 1});
    }
    span.debug("Successfully encoded all {d} pools", .{core_count});
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const testing = std.testing;

test "Alpha encode" {
    const C = 341;
    var alpha = Alpha(C).init();
    const core: usize = 0;
    const auth1: [32]u8 = [_]u8{1} ** 32;
    const auth2: [32]u8 = [_]u8{2} ** 32;

    try alpha.pools[core].append(auth1);
    try alpha.pools[core].append(auth2);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try encode(C, &alpha, buffer.writer());

    // Expected output:
    // - 2 (number of items in the first pool)
    // - auth1 (32 bytes)
    // - auth2 (32 bytes)
    // - 0 (number of items in all other pools)
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
