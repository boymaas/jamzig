const std = @import("std");
const sort = std.sort;
const encoder = @import("../codec/encoder.zig");
const HashSet = @import("../datastruct/hash_set.zig").HashSet;

const trace = @import("tracing").scoped(.codec);

const makeLessThanSliceOfFn = @import("../utils/sort.zig").makeLessThanSliceOfFn;
const lessThanSliceOfHashes = makeLessThanSliceOfFn([32]u8);

/// Xi (ξ) is defined as a dictionary mapping hashes to hashes: D⟨H → H⟩E
/// where H represents 32-byte hashes
pub fn encode(comptime epoch_size: usize, allocator: std.mem.Allocator, xi: *const [epoch_size]HashSet([32]u8), writer: anytype) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting Xi encoding for {d} epochs", .{epoch_size});

    for (xi, 0..) |*epoch, i| {
        span.debug("Encoding epoch {d}/{d}", .{ i + 1, epoch_size });
        try encodeTimeslotEntry(allocator, epoch, writer);
    }

    span.debug("Successfully encoded all epochs", .{});
}

pub fn encodeTimeslotEntry(allocator: std.mem.Allocator, xi: *const HashSet([32]u8), writer: anytype) !void {
    const span = trace.span(@src(), .encode_timeslot);
    defer span.deinit();

    const entry_count = xi.count();
    span.debug("Encoding timeslot entry with {d} mappings", .{entry_count});

    try writer.writeAll(encoder.encodeInteger(entry_count).as_slice());
    span.trace("Wrote entry count prefix", .{});

    var keys = try std.ArrayList([32]u8).initCapacity(allocator, entry_count);
    defer keys.deinit();

    var iter = xi.keyIterator();
    while (iter.next()) |key| {
        try keys.append(key);
    }
    span.trace("Collected {d} keys", .{keys.items.len});

    sort.insertion([32]u8, keys.items, {}, lessThanSliceOfHashes);
    span.debug("Sorted keys for deterministic encoding", .{});

    for (keys.items, 0..) |key, i| {
        span.trace("Writing {d}/{d} - key: {any}", .{ i + 1, keys.items.len, std.fmt.fmtSliceHexLower(&key) });

        try writer.writeAll(&key);
    }

    span.debug("Successfully encoded timeslot entry", .{});
}

test "Xi encode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var xi = HashSet([32]u8).init();
    defer xi.deinit(allocator);

    const key1 = [_]u8{3} ** 32;
    const key2 = [_]u8{1} ** 32;

    try xi.add(allocator, key1);
    try xi.add(allocator, key2);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encodeTimeslotEntry(allocator, &xi, buffer.writer());

    try testing.expectEqual(@as(u8, 2), buffer.items[0]);

    try testing.expectEqualSlices(u8, &key2, buffer.items[1..33]);
    try testing.expectEqualSlices(u8, &key1, buffer.items[33..65]);

    try testing.expectEqual(@as(usize, 65), buffer.items.len);
}
