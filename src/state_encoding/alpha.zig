const std = @import("std");
const encoder = @import("../codec/encoder.zig");

const authorization = @import("../authorization.zig");
const Alpha = authorization.Alpha;

/// Encodes pools where each pool is length encoded. Length of pools is assumed to be C
pub fn encode(comptime core_count: u16, self: *const Alpha(core_count), writer: anytype) !void {
    // Encode pools
    for (self.pools) |pool| {
        try writer.writeAll(encoder.encodeInteger(pool.len).as_slice());
        for (pool.constSlice()) |auth| {
            try writer.writeAll(&auth);
        }
    }
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
