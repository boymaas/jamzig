const std = @import("std");
const types = @import("../types.zig");
const codec = @import("../codec.zig");

pub fn encode(set: *const types.ValidatorSet, writer: anytype) !void {
    try codec.serializeSliceAsArray(types.ValidatorData, writer, set.items());
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const testing = std.testing;

test "encode" {
    const allocator = testing.allocator;

    // Create sample ValidatorData
    var validator_set = try types.ValidatorSet.init(allocator, 2);
    validator_set.items()[0] = .{
        .bandersnatch = [_]u8{1} ** 32,
        .ed25519 = [_]u8{2} ** 32,
        .bls = [_]u8{3} ** 144,
        .metadata = [_]u8{4} ** 128,
    };

    validator_set.items()[1] = .{
        .bandersnatch = [_]u8{5} ** 32,
        .ed25519 = [_]u8{6} ** 32,
        .bls = [_]u8{7} ** 144,
        .metadata = [_]u8{8} ** 128,
    };
    defer validator_set.deinit(allocator);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encode(&validator_set, buffer.writer());

    // Check if the encoded data is not empty
    try testing.expect(buffer.items.len > 0);

    // Since this should be encoded without any size prefix we should be able to check the values
    // in memory match up
    var offset: usize = 0;
    for (validator_set.items()) |validator| {
        try testing.expectEqual(validator.bandersnatch, buffer.items[offset .. offset + 32][0..32].*);
        offset += 32;
        try testing.expectEqual(validator.ed25519, buffer.items[offset .. offset + 32][0..32].*);
        offset += 32;
        try testing.expectEqual(validator.bls, buffer.items[offset .. offset + 144][0..144].*);
        offset += 144;
        try testing.expectEqual(validator.metadata, buffer.items[offset .. offset + 128][0..128].*);
        offset += 128;
    }

    // Ensure we've checked all bytes in the buffer
    try testing.expectEqual(buffer.items.len, offset);
}
