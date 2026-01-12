const std = @import("std");
const testing = std.testing;
const authorization_pool = @import("../authorizer_pool.zig");
const decoder = @import("../codec/decoder.zig");
const codec = @import("../codec.zig");
const Alpha = authorization_pool.Alpha;
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub const DecoderParams = struct {
    core_count: u16,
    max_authorizations_pool_items: u8,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .core_count = params.core_count,
            .max_authorizations_pool_items = params.max_authorizations_pool_items,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Alpha(params.core_count, params.max_authorizations_pool_items) {
    _ = allocator; // For API consistency

    try context.push(.{ .component = "alpha" });
    defer context.pop();

    var alpha = Alpha(params.core_count, params.max_authorizations_pool_items).init();

    try context.push(.{ .field = "pools" });
    for (0..params.core_count) |core| {
        try context.push(.{ .array_index = core });

        try context.push(.{ .field = "length" });
        const pool_len = codec.readInteger(reader) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read pool length: {s}", .{@errorName(err)});
        };

        if (pool_len > params.max_authorizations_pool_items) {
            return context.makeError(error.ExceededMaximumSize, "pool length {} exceeds maximum {}", .{ pool_len, params.max_authorizations_pool_items });
        }
        context.pop();

        try context.push(.{ .field = "authorizations" });
        var i: usize = 0;
        while (i < pool_len) : (i += 1) {
            try context.push(.{ .array_index = i });

            var auth: [32]u8 = undefined;
            reader.readNoEof(&auth) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read authorization: {s}", .{@errorName(err)});
            };

            alpha.pools[core].append(auth) catch |err| {
                return context.makeError(error.ExceededMaximumSize, "failed to append authorization: {s}", .{@errorName(err)});
            };

            context.pop();
        }
        context.pop(); // authorizations

        context.pop(); // array_index
    }
    context.pop(); // pools

    return alpha;
}

test "decode alpha - empty pools" {
    const allocator = testing.allocator;
    const params = comptime DecoderParams{
        .core_count = 2,
        .max_authorizations_pool_items = 8,
    };

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.writer().writeInt(u32, 0, .little);
    try buffer.writer().writeInt(u32, 0, .little);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const alpha = try decode(params, allocator, &context, fbs.reader());

    for (alpha.pools) |pool| {
        try testing.expectEqual(@as(usize, 0), pool.len);
    }
}

test "decode alpha - with authorizations" {
    const allocator = testing.allocator;
    const params = comptime DecoderParams{
        .core_count = 2,
        .max_authorizations_pool_items = 8,
    };

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var writer = buffer.writer();

    try codec.writeInteger(1, writer);
    try writer.writeAll(&[_]u8{1} ** 32);

    try codec.writeInteger(2, writer);
    try writer.writeAll(&[_]u8{2} ** 32);
    try writer.writeAll(&[_]u8{3} ** 32);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const alpha = try decode(params, allocator, &context, fbs.reader());

    try testing.expectEqual(@as(usize, 1), alpha.pools[0].len);
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 32, &alpha.pools[0].constSlice()[0]);

    try testing.expectEqual(@as(usize, 2), alpha.pools[1].len);
    try testing.expectEqualSlices(u8, &[_]u8{2} ** 32, &alpha.pools[1].constSlice()[0]);
    try testing.expectEqualSlices(u8, &[_]u8{3} ** 32, &alpha.pools[1].constSlice()[1]);
}

test "decode alpha - insufficient data" {
    const allocator = testing.allocator;
    const params = comptime DecoderParams{
        .core_count = 2,
        .max_authorizations_pool_items = 8,
    };

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = [_]u8{ 1, 0 };
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(params, allocator, &context, fbs.reader()));
    }

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = [_]u8{ 1, 0, 0, 0 } ++ [_]u8{1} ** 16;
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(params, allocator, &context, fbs.reader()));
    }
}

test "decode alpha - roundtrip" {
    const encoder = @import("../state_encoding/alpha.zig");
    const params = comptime DecoderParams{
        .core_count = 2,
        .max_authorizations_pool_items = 8,
    };
    const allocator = testing.allocator;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var original = Alpha(params.core_count, params.max_authorizations_pool_items).init();
    const auth1: [32]u8 = [_]u8{1} ** 32;
    const auth2: [32]u8 = [_]u8{2} ** 32;
    try original.pools[0].append(auth1);
    try original.pools[1].append(auth2);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(params.core_count, params.max_authorizations_pool_items, &original, buffer.writer());

    var fbs = std.io.fixedBufferStream(buffer.items);
    const decoded = try decode(params, allocator, &context, fbs.reader());

    for (original.pools, 0..) |pool, i| {
        try testing.expectEqual(pool.len, decoded.pools[i].len);
        try testing.expectEqualSlices([32]u8, pool.constSlice(), decoded.pools[i].constSlice());
    }
}
