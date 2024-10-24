const std = @import("std");
const sort = std.sort;
const encoder = @import("../codec/encoder.zig");

const makeLessThanSliceOfFn = @import("../utils/sort.zig").makeLessThanSliceOfFn;
const lessThanSliceOfHashes = makeLessThanSliceOfFn([32]u8);

/// Xi (ξ) is defined as a dictionary mapping hashes to hashes: D⟨H → H⟩E
/// where H represents 32-byte hashes
pub fn encode(comptime epoch_size: usize, allocator: std.mem.Allocator, xi: *const [epoch_size]std.AutoHashMapUnmanaged([32]u8, [32]u8), writer: anytype) !void {
    for (xi) |*epoch| {
        try encodeTimeslotEntry(allocator, epoch, writer);
    }
}

pub fn encodeTimeslotEntry(allocator: std.mem.Allocator, xi: *const std.AutoHashMapUnmanaged([32]u8, [32]u8), writer: anytype) !void {
    // First encode the number of mappings
    try writer.writeAll(encoder.encodeInteger(xi.count()).as_slice());

    // Sort the keys to ensure deterministic encoding
    var keys = try std.ArrayList([32]u8).initCapacity(allocator, xi.count());
    defer keys.deinit();

    var iter = xi.keyIterator();
    while (iter.next()) |key| {
        try keys.append(key.*);
    }

    // Use std.sort.insertionSort since we expect small maps
    sort.insertion([32]u8, keys.items, {}, lessThanSliceOfHashes);

    // Write each key-value pair in sorted order
    for (keys.items) |key| {
        // Write key
        try writer.writeAll(&key);
        // Write corresponding value
        try writer.writeAll(&xi.get(key).?);
    }
}

test "Xi encode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test xi mapping
    var xi: std.AutoHashMapUnmanaged([32]u8, [32]u8) = .{};
    defer xi.deinit(allocator);

    // Create some test hashes
    const key1 = [_]u8{3} ** 32;
    const val1 = [_]u8{2} ** 32;
    const key2 = [_]u8{1} ** 32;
    const val2 = [_]u8{4} ** 32;

    try xi.put(allocator, key1, val1);
    try xi.put(allocator, key2, val2);

    // Create buffer for output
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encodeTimeslotEntry(allocator, &xi, buffer.writer());

    // Validate encoding
    // First byte should be the length (2)
    try testing.expectEqual(@as(u8, 2), buffer.items[0]);

    // Should be followed by sorted key-value pairs
    // Key2 should come first as dicst should be sorted
    try testing.expectEqualSlices(u8, &key2, buffer.items[1..33]);
    try testing.expectEqualSlices(u8, &val2, buffer.items[33..65]);
    try testing.expectEqualSlices(u8, &key1, buffer.items[65..97]);
    try testing.expectEqualSlices(u8, &val1, buffer.items[97..129]);

    // Total size should be:
    // 1 byte length prefix + (2 pairs * (32 bytes key + 32 bytes value))
    try testing.expectEqual(@as(usize, 129), buffer.items.len);
}
