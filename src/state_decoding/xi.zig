const std = @import("std");
const sort = std.sort;
const decoder = @import("../codec/decoder.zig");
const state = @import("../state.zig");

pub fn decode(comptime epoch_size: usize, allocator: std.mem.Allocator, reader: anytype) !state.Xi(epoch_size) {
    var result: [epoch_size]std.AutoHashMapUnmanaged([32]u8, [32]u8) = undefined;
    for (&result) |*epoch| {
        epoch.* = try decodeTimeslotEntry(allocator, reader);
    }
    return .{ .entries = result, .allocator = allocator };
}

pub fn decodeTimeslotEntry(allocator: std.mem.Allocator, reader: anytype) !std.AutoHashMapUnmanaged([32]u8, [32]u8) {
    var result = std.AutoHashMapUnmanaged([32]u8, [32]u8){};
    errdefer result.deinit(allocator);

    // Read length prefix
    var length_buf: [1]u8 = undefined;
    _ = try reader.readAll(&length_buf);
    const count = length_buf[0];

    // Read each key-value pair
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key: [32]u8 = undefined;
        var value: [32]u8 = undefined;

        _ = try reader.readAll(&key);
        _ = try reader.readAll(&value);

        try result.put(allocator, key, value);
    }

    return result;
}

test "Xi decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test data
    const key1 = [_]u8{3} ** 32;
    const val1 = [_]u8{2} ** 32;
    const key2 = [_]u8{1} ** 32;
    const val2 = [_]u8{4} ** 32;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write test data (matching encode test)
    try buffer.append(2); // count
    try buffer.appendSlice(&key2);
    try buffer.appendSlice(&val2);
    try buffer.appendSlice(&key1);
    try buffer.appendSlice(&val1);

    var stream = std.io.fixedBufferStream(buffer.items);
    var xi = try decodeTimeslotEntry(allocator, stream.reader());
    defer xi.deinit(allocator);

    // Validate decoded data
    try testing.expectEqual(@as(usize, 2), xi.count());
    try testing.expectEqualSlices(u8, &val1, &xi.get(key1).?);
    try testing.expectEqualSlices(u8, &val2, &xi.get(key2).?);
}
