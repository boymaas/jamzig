const std = @import("std");
const sort = std.sort;
const encoder = @import("../codec/encoder.zig");

const trace = @import("../tracing.zig").scoped(.codec);

const makeLessThanSliceOfFn = @import("../utils/sort.zig").makeLessThanSliceOfFn;
const lessThanSliceOfHashes = makeLessThanSliceOfFn([32]u8);

/// Xi (ξ) is defined as a dictionary mapping hashes to hashes: D⟨H → H⟩E
/// where H represents 32-byte hashes
pub fn encode(comptime epoch_size: usize, allocator: std.mem.Allocator, xi: *const [epoch_size]std.AutoHashMapUnmanaged([32]u8, void), writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting Xi encoding for {d} epochs", .{epoch_size});

    for (xi, 0..) |*epoch, i| {
        span.debug("Encoding epoch {d}/{d}", .{ i + 1, epoch_size });
        try encodeTimeslotEntry(allocator, epoch, writer);
    }

    span.debug("Successfully encoded all epochs", .{});
}

pub fn encodeTimeslotEntry(allocator: std.mem.Allocator, xi: *const std.AutoHashMapUnmanaged([32]u8, void), writer: anytype) !void {
    const span = trace.span(.encode_timeslot);
    defer span.deinit();

    const entry_count = xi.count();
    span.debug("Encoding timeslot entry with {d} mappings", .{entry_count});

    // First encode the number of mappings
    try writer.writeAll(encoder.encodeInteger(entry_count).as_slice());
    span.trace("Wrote entry count prefix", .{});

    // Sort the keys to ensure deterministic encoding
    var keys = try std.ArrayList([32]u8).initCapacity(allocator, entry_count);
    defer keys.deinit();

    var iter = xi.keyIterator();
    while (iter.next()) |key| {
        try keys.append(key.*);
    }
    span.trace("Collected {d} keys", .{keys.items.len});

    // Use std.sort.insertionSort since we expect small maps
    sort.insertion([32]u8, keys.items, {}, lessThanSliceOfHashes);
    span.debug("Sorted keys for deterministic encoding", .{});

    // Write each key-value pair in sorted order
    for (keys.items, 0..) |key, i| {
        span.trace("Writing {d}/{d} - key: {any}", .{ i + 1, keys.items.len, std.fmt.fmtSliceHexLower(&key) });

        // Write key
        try writer.writeAll(&key);
    }

    span.debug("Successfully encoded timeslot entry", .{});
}

test "Xi encode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test xi mapping
    var xi: std.AutoHashMapUnmanaged([32]u8, void) = .{};
    defer xi.deinit(allocator);

    // Create some test hashes
    const key1 = [_]u8{3} ** 32;
    const key2 = [_]u8{1} ** 32;

    try xi.put(allocator, key1, {});
    try xi.put(allocator, key2, {});

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
    try testing.expectEqualSlices(u8, &key1, buffer.items[33..65]);

    // Total size should be:
    // 1 byte length prefix + (2 pairs * 32 bytes key)
    try testing.expectEqual(@as(usize, 65), buffer.items.len);
}
