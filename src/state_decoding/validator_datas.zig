const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const ValidatorSet = types.ValidatorSet;
const ValidatorData = types.ValidatorData;
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    validators_count: u32,
    reader: anytype,
) !ValidatorSet {
    try context.push(.{ .component = "validator_datas" });
    defer context.pop();

    var validator_set = try ValidatorSet.init(allocator, validators_count);
    errdefer validator_set.deinit(allocator);

    // Read each validator's data sequentially
    for (validator_set.validators, 0..) |*validator, i| {
        try context.push(.{ .array_index = i });
        
        // Read bandersnatch public key
        try context.push(.{ .field = "bandersnatch" });
        reader.readNoEof(&validator.bandersnatch) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read bandersnatch key: {s}", .{@errorName(err)});
        };
        context.pop();

        // Read ed25519 public key
        try context.push(.{ .field = "ed25519" });
        reader.readNoEof(&validator.ed25519) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read ed25519 key: {s}", .{@errorName(err)});
        };
        context.pop();

        // Read bls public key
        try context.push(.{ .field = "bls" });
        reader.readNoEof(&validator.bls) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read bls key: {s}", .{@errorName(err)});
        };
        context.pop();

        // Read metadata
        try context.push(.{ .field = "metadata" });
        reader.readNoEof(&validator.metadata) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read metadata: {s}", .{@errorName(err)});
        };
        context.pop();
        
        context.pop(); // array_index
    }

    return validator_set;
}

test "decode validator_datas - empty set" {
    const allocator = testing.allocator;
    const validators_count: u32 = 0;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var fbs = std.io.fixedBufferStream(buffer.items);
    var validator_set = try decode(allocator, &context, validators_count, fbs.reader());
    defer validator_set.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), validator_set.len());
}

test "decode validator_datas - single validator" {
    const allocator = testing.allocator;
    const validators_count: u32 = 1;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write validator data
    try buffer.appendSlice(&[_]u8{1} ** 32); // bandersnatch
    try buffer.appendSlice(&[_]u8{2} ** 32); // ed25519
    try buffer.appendSlice(&[_]u8{3} ** 144); // bls
    try buffer.appendSlice(&[_]u8{4} ** 128); // metadata

    var fbs = std.io.fixedBufferStream(buffer.items);
    var validator_set = try decode(allocator, &context, validators_count, fbs.reader());
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

    var context = DecodingContext.init(allocator);
    defer context.deinit();

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
    var validator_set = try decode(allocator, &context, validators_count, fbs.reader());
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
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(&[_]u8{1} ** 16); // Only half of bandersnatch key

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, validators_count, fbs.reader()));
    }

    // Test truncated ed25519 key
    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(&[_]u8{1} ** 32); // Complete bandersnatch
        try buffer.appendSlice(&[_]u8{2} ** 16); // Half ed25519

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, validators_count, fbs.reader()));
    }

    // Test truncated bls key
    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(&[_]u8{1} ** 32); // bandersnatch
        try buffer.appendSlice(&[_]u8{2} ** 32); // ed25519
        try buffer.appendSlice(&[_]u8{3} ** 72); // Half bls

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, validators_count, fbs.reader()));
    }
}

test "decode validator_datas - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/validator_datas.zig");
    const validators_count: u32 = 2;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

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
    var decoded = try decode(allocator, &context, validators_count, fbs.reader());
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
