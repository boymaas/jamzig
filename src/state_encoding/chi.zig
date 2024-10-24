const std = @import("std");
const state = @import("../state.zig");
const serialize = @import("../codec.zig").serialize;
const encoder = @import("../codec/encoder.zig");

pub fn encode(chi: *const state.Chi, writer: anytype) !void {
    // Encode the simple fields
    try writer.writeInt(u32, chi.manager orelse 0, .little);
    try writer.writeInt(u32, chi.assign orelse 0, .little);
    try writer.writeInt(u32, chi.designate orelse 0, .little);

    // Encode X_g with ordered keys
    // TODO: this could be a method in encoder, map encoder which orders
    // the keys
    var keys = std.ArrayList(u32).init(chi.allocator);
    defer keys.deinit();

    var it = chi.always_accumulate.keyIterator();
    while (it.next()) |key| {
        try keys.append(key.*);
    }

    std.sort.insertion(u32, keys.items, {}, std.sort.asc(u32));

    try writer.writeAll(encoder.encodeInteger(keys.items.len).as_slice());

    for (keys.items) |key| {
        const value = chi.always_accumulate.get(key).?;
        try writer.writeInt(u32, key, .little);
        try writer.writeInt(u64, value, .little);
    }
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const decoder = @import("../codec/decoder.zig");

test "Chi serialization" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    var chi = state.Chi.init(allocator);
    defer chi.deinit();

    // Set some test values
    chi.manager = 1;
    chi.assign = 2;
    chi.designate = 3;
    try chi.always_accumulate.put(14, 1000);
    try chi.always_accumulate.put(6, 1000);
    try chi.always_accumulate.put(8, 1000);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encode(&chi, buffer.writer());

    // Calculate expected length:
    // 3 * u32 (manager, assign, designate) + u8 (map length) + 3 * (u32 + u64) (map entries)
    const expected_length = 3 * 4 + 1 + 3 * (4 + 8);
    try testing.expectEqual(expected_length, buffer.items.len);

    // Check if the keys are ordered correctly
    var stream = std.io.fixedBufferStream(buffer.items);
    const reader = stream.reader();
    const manager = try reader.readInt(u32, .little);
    const assign = try reader.readInt(u32, .little);
    const designate = try reader.readInt(u32, .little);

    // Assert that the read values match the original values
    try testing.expectEqual(chi.manager, manager);
    try testing.expectEqual(chi.assign, assign);
    try testing.expectEqual(chi.designate, designate);

    const map_length = try decoder.decodeInteger(reader.context.buffer[reader.context.pos..]);
    try testing.expectEqual(@as(u32, 3), map_length.value);
    reader.context.pos += map_length.bytes_read;

    var last_key: u32 = 0;
    var i: u32 = 0;
    while (i < @as(usize, @intCast(map_length.value))) : (i += 1) {
        const key = try reader.readInt(u32, .little);
        const value = try reader.readInt(u64, .little);
        if (i > 0) {
            try testing.expect(key > last_key);
        }
        last_key = key;

        // Assert that the read key-value pair matches the original map
        try testing.expectEqual(chi.always_accumulate.get(key).?, value);
    }
}
