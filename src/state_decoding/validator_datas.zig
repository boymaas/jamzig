const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const ValidatorSet = types.ValidatorSet;
const ValidatorData = types.ValidatorData;

pub fn decode(allocator: std.mem.Allocator, validators_count: u32, reader: anytype) !ValidatorSet {
    var validator_set = try ValidatorSet.init(allocator, validators_count);
    errdefer validator_set.deinit(allocator);

    // Read each validator's data sequentially
    for (validator_set.validators) |*validator| {
        // Read bandersnatch public key
        try reader.readNoEof(&validator.bandersnatch);

        // Read ed25519 public key
        try reader.readNoEof(&validator.ed25519);

        // Read bls public key
        try reader.readNoEof(&validator.bls);

        // Read metadata
        try reader.readNoEof(&validator.metadata);
    }

    return validator_set;
}

test "decode validator_datas - empty set" {
    const allocator = testing.allocator;
    const validators_count: u32 = 0;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var fbs = std.io.fixedBufferStream(buffer.items);
    var validator_set = try decode(allocator, validators_count, fbs.reader());
    defer validator_set.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), validator_set.len());
}

test "decode validator_datas - single validator" {
    const allocator = testing.allocator;
    const validators_count: u32 = 1;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write validator data
    try buffer.appendSlice(&[_]u8{1} ** 32); // bandersnatch
    try buffer.appendSlice(&[_]u8{2} ** 32); // ed25519
    try buffer.appendSlice(&[_]u8{3} ** 144); // bls
    try buffer.appendSlice(&[_]u8{4} ** 128); // metadata

    var fbs = std.io.fixedBufferStream(buffer.items);
    var validator_set = try decode(allocator, validators_count, fbs.reader());
    defer validator_set.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), validator_set.len());

    const validator = validator_set.items()[0];
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &validator.bandersnatch);
    try testing.expectEqualSlices(u8, &[_]u8{2} ** 32, &validator.ed25519);
    try testing.expectEqualSlices(u8, &[_]u8{3} ** 144, &validator.bls);
    try testing.expectEqualSlices(u8, &[_]u8{4} ** 128, &validator.metadata);
}

test "decode validator_datas - multiple validators" {
    const allocator = testing.allocator;
    const validators_count: u32 = 3;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write three validators with different data
    for (0..3) |i| {
        const val: u8 = @intCast(i + 1);
        try buffer.appendSlice(&[_]u8{val} ** 32); // bandersnatch
        try buffer.appendSlice(&[_]u8{val + 1} ** 32); // ed25519
        try buffer.appendSlice(&[_]u8{val + 2} ** 144); // bls
        try buffer.appendSlice(&[_]u8{val + 3} ** 128); // metadata
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    var validator_set = try decode(allocator, validators_count, fbs.reader());
    defer validator_set.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), validator_set.len());

    for (validator_set.items(), 0..) |validator, i| {
        const val: u8 = @intCast(i + 1);
        try testing.expectEqualSlices(u8, &[_]u8{val} ** 32, &validator.bandersnatch);
        try testing.expectEqualSlices(u8, &[_]u8{val + 1} ** 32, &validator.ed25519);
        try testing.expectEqualSlices(u8, &[_]u8{val + 2} ** 144, &validator.bls);
        try testing.expectEqualSlices(u8, &[_]u8{val + 3} ** 128, &validator.metadata);
    }
}

test "decode validator_datas - insufficient data" {
    const allocator = testing.allocator;
    const validators_count: u32 = 1;

    // Test truncated bandersnatch key
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(&[_]u8{1} ** 16); // Only half of bandersnatch key

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, validators_count, fbs.reader()));
    }

    // Test truncated ed25519 key
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(&[_]u8{1} ** 32); // Complete bandersnatch
        try buffer.appendSlice(&[_]u8{2} ** 16); // Half ed25519

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, validators_count, fbs.reader()));
    }

    // Test truncated bls key
    {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(&[_]u8{1} ** 32); // bandersnatch
        try buffer.appendSlice(&[_]u8{2} ** 32); // ed25519
        try buffer.appendSlice(&[_]u8{3} ** 72); // Half bls

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, validators_count, fbs.reader()));
    }
}

test "decode validator_datas - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/validator_datas.zig");
    const validators_count: u32 = 2;

    // Create original validator set
    var original = try ValidatorSet.init(allocator, validators_count);
    defer original.deinit(allocator);

    // Set test data
    original.items()[0] = .{
        .bandersnatch = [_]u8{1} ** 32,
        .ed25519 = [_]u8{2} ** 32,
        .bls = [_]u8{3} ** 144,
        .metadata = [_]u8{4} ** 128,
    };
    original.items()[1] = .{
        .bandersnatch = [_]u8{5} ** 32,
        .ed25519 = [_]u8{6} ** 32,
        .bls = [_]u8{7} ** 144,
        .metadata = [_]u8{8} ** 128,
    };

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(allocator, validators_count, fbs.reader());
    defer decoded.deinit(allocator);

    // Verify set size
    try testing.expectEqual(original.len(), decoded.len());

    // Verify validator data
    for (original.items(), decoded.items()) |orig, dec| {
        try testing.expectEqualSlices(u8, &orig.bandersnatch, &dec.bandersnatch);
        try testing.expectEqualSlices(u8, &orig.ed25519, &dec.ed25519);
        try testing.expectEqualSlices(u8, &orig.bls, &dec.bls);
        try testing.expectEqualSlices(u8, &orig.metadata, &dec.metadata);
    }
}
