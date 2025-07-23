const std = @import("std");
const testing = std.testing;
const services_privileged = @import("../services_priviledged.zig");
const Chi = services_privileged.Chi;
const decoder = @import("../codec/decoder.zig");
const codec = @import("../codec.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Chi {
    try context.push(.{ .component = "chi" });
    defer context.pop();

    var chi = Chi.init(allocator);
    errdefer chi.deinit();

    // Read manager index
    try context.push(.{ .field = "manager" });
    const manager_idx = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read manager index: {s}", .{@errorName(err)});
    };
    chi.manager = if (manager_idx == 0) null else manager_idx;
    context.pop();

    // Read assign index
    try context.push(.{ .field = "assign" });
    const assign_idx = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read assign index: {s}", .{@errorName(err)});
    };
    chi.assign = if (assign_idx == 0) null else assign_idx;
    context.pop();

    // Read designate index
    try context.push(.{ .field = "designate" });
    const designate_idx = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read designate index: {s}", .{@errorName(err)});
    };
    chi.designate = if (designate_idx == 0) null else designate_idx;
    context.pop();

    // Read always_accumulate map
    try context.push(.{ .field = "always_accumulate" });
    const map_len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read map length: {s}", .{@errorName(err)});
    };

    // Read always_accumulate entries (ordered by key)
    var prev_key: ?u32 = null;
    var i: usize = 0;
    while (i < map_len) : (i += 1) {
        try context.push(.{ .array_index = i });

        const key = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read map key: {s}", .{@errorName(err)});
        };
        const value = reader.readInt(u64, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read map value: {s}", .{@errorName(err)});
        };

        // Validate ordering
        if (prev_key) |pk| {
            if (key <= pk) {
                return context.makeError(error.InvalidFormat, "map keys must be sorted, but {} <= {}", .{ key, pk });
            }
        }
        prev_key = key;

        chi.always_accumulate.put(key, value) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to insert map entry: {s}", .{@errorName(err)});
        };

        context.pop();
    }
    context.pop(); // always_accumulate

    return chi;
}

test "decode chi - empty state" {
    const allocator = testing.allocator;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create buffer with zero/null values
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write null indices
    try buffer.writer().writeInt(u32, 0, .little); // manager
    try buffer.writer().writeInt(u32, 0, .little); // assign
    try buffer.writer().writeInt(u32, 0, .little); // designate

    // Write empty map
    try buffer.append(0); // map length

    var fbs = std.io.fixedBufferStream(buffer.items);
    var chi = try decode(allocator, &context, fbs.reader());
    defer chi.deinit();

    // Verify empty state
    try testing.expect(chi.manager == null);
    try testing.expect(chi.assign == null);
    try testing.expect(chi.designate == null);
    try testing.expectEqual(@as(usize, 0), chi.always_accumulate.count());
}

test "decode chi - with values" {
    const allocator = testing.allocator;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create test buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write service indices
    try buffer.writer().writeInt(u32, 1, .little); // manager
    try buffer.writer().writeInt(u32, 2, .little); // assign
    try buffer.writer().writeInt(u32, 3, .little); // designate

    // Write map with 2 entries
    try buffer.append(2); // map length

    // Write sorted entries
    try buffer.writer().writeInt(u32, 5, .little); // key 1
    try buffer.writer().writeInt(u64, 1000, .little); // value 1
    try buffer.writer().writeInt(u32, 10, .little); // key 2
    try buffer.writer().writeInt(u64, 2000, .little); // value 2

    var fbs = std.io.fixedBufferStream(buffer.items);
    var chi = try decode(allocator, &context, fbs.reader());
    defer chi.deinit();

    // Verify service indices
    try testing.expectEqual(@as(?u32, 1), chi.manager);
    try testing.expectEqual(@as(?u32, 2), chi.assign);
    try testing.expectEqual(@as(?u32, 3), chi.designate);

    // Verify map entries
    try testing.expectEqual(@as(usize, 2), chi.always_accumulate.count());
    try testing.expectEqual(@as(u64, 1000), chi.always_accumulate.get(5).?);
    try testing.expectEqual(@as(u64, 2000), chi.always_accumulate.get(10).?);
}

test "decode chi - insufficient data" {
    const allocator = testing.allocator;

    // Test truncated indices
    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0 }; // Only 2 indices, missing third
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }

    // Test truncated map entry
    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Write indices
        try buffer.writer().writeInt(u32, 1, .little);
        try buffer.writer().writeInt(u32, 2, .little);
        try buffer.writer().writeInt(u32, 3, .little);

        // Write map length but insufficient entries
        try buffer.append(1); // One entry
        try buffer.writer().writeInt(u32, 5, .little); // key only, missing value

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }
}

test "decode chi - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/chi.zig");

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create original chi state
    var original = Chi.init(allocator);
    defer original.deinit();

    // Set values
    original.manager = 1;
    original.assign = 2;
    original.designate = 3;
    try original.always_accumulate.put(5, 1000);
    try original.always_accumulate.put(10, 2000);

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(allocator, &context, fbs.reader());
    defer decoded.deinit();

    // Verify service indices
    try testing.expectEqual(original.manager, decoded.manager);
    try testing.expectEqual(original.assign, decoded.assign);
    try testing.expectEqual(original.designate, decoded.designate);

    // Verify map contents
    try testing.expectEqual(original.always_accumulate.count(), decoded.always_accumulate.count());
    var it = original.always_accumulate.iterator();
    while (it.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, decoded.always_accumulate.get(entry.key_ptr.*).?);
    }
}
