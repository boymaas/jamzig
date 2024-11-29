const std = @import("std");
const testing = std.testing;
const authorization = @import("../authorization.zig");
const decoder = @import("../codec/decoder.zig");
const codec = @import("../codec.zig");
const Alpha = authorization.Alpha;

pub fn decode(comptime core_count: u16, reader: anytype) !Alpha(core_count) {
    var alpha = Alpha(core_count).init();

    // For each core's pool
    for (0..core_count) |core| {
        // Read pool length
        const pool_len = try codec.readInteger(reader);

        // Read pool authorizations
        var i: usize = 0;
        while (i < pool_len) : (i += 1) {
            var auth: [32]u8 = undefined;
            try reader.readNoEof(&auth);
            try alpha.pools[core].append(auth);
        }
    }

    return alpha;
}

test "decode alpha - empty pools" {
    const allocator = testing.allocator;
    const core_count: u16 = 2;

    // Create buffer with zero-length pools
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write lengths of 0 for each pool
    try buffer.writer().writeInt(u32, 0, .little);
    try buffer.writer().writeInt(u32, 0, .little);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const alpha = try decode(core_count, fbs.reader());

    // Verify empty pools
    for (alpha.pools) |pool| {
        try testing.expectEqual(@as(usize, 0), pool.len);
    }
}

test "decode alpha - with authorizations" {
    const allocator = testing.allocator;
    const core_count: u16 = 2;

    // Create test data
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var writer = buffer.writer();

    // Core 0: Write length 1 and one authorization
    try codec.writeInteger(1, writer);
    try writer.writeAll(&[_]u8{1} ** 32);

    // Core 1: Write length 2 and two authorizations
    try codec.writeInteger(2, writer);
    try writer.writeAll(&[_]u8{2} ** 32);
    try writer.writeAll(&[_]u8{3} ** 32);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const alpha = try decode(core_count, fbs.reader());

    // Verify Core 0
    try testing.expectEqual(@as(usize, 1), alpha.pools[0].len);
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &alpha.pools[0].constSlice()[0]);

    // Verify Core 1
    try testing.expectEqual(@as(usize, 2), alpha.pools[1].len);
    try testing.expectEqualSlices(u8, &[_]u8{2} ** 32, &alpha.pools[1].constSlice()[0]);
    try testing.expectEqualSlices(u8, &[_]u8{3} ** 32, &alpha.pools[1].constSlice()[1]);
}

test "decode alpha - insufficient data" {
    const core_count: u16 = 2;

    // Test truncated length
    {
        var buffer = [_]u8{ 1, 0 }; // Incomplete u32
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(core_count, fbs.reader()));
    }

    // Test truncated authorization
    {
        var buffer = [_]u8{ 1, 0, 0, 0 } ++ [_]u8{1} ** 16; // Only half auth
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(core_count, fbs.reader()));
    }
}

test "decode alpha - roundtrip" {
    const encoder = @import("../state_encoding/alpha.zig");
    const core_count: u16 = 2;
    const allocator = testing.allocator;

    // Create sample alpha state
    var original = Alpha(core_count).init();
    const auth1: [32]u8 = [_]u8{1} ** 32;
    const auth2: [32]u8 = [_]u8{2} ** 32;
    try original.pools[0].append(auth1);
    try original.pools[1].append(auth2);

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(core_count, &original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    const decoded = try decode(core_count, fbs.reader());

    // Verify pools
    for (original.pools, 0..) |pool, i| {
        try testing.expectEqual(pool.len, decoded.pools[i].len);
        try testing.expectEqualSlices([32]u8, pool.constSlice(), decoded.pools[i].constSlice());
    }
}
