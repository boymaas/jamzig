
const std = @import("std");
const testing = std.testing;
const disputes = @import("../disputes.zig");
const Psi = disputes.Psi;
const Hash = disputes.Hash;
const PublicKey = disputes.PublicKey;
const decoder = @import("../codec/decoder.zig");
const codec = @import("../codec.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Psi {
    try context.push(.{ .component = "psi" });
    defer context.pop();

    var psi = Psi.init(allocator);
    errdefer psi.deinit();

    try context.push(.{ .field = "good_set" });
    try decodeHashSet(context, &psi.good_set, reader);
    context.pop();

    try context.push(.{ .field = "bad_set" });
    try decodeHashSet(context, &psi.bad_set, reader);
    context.pop();

    try context.push(.{ .field = "wonky_set" });
    try decodeHashSet(context, &psi.wonky_set, reader);
    context.pop();

    try context.push(.{ .field = "punish_set" });
    try decodeHashSet(context, &psi.punish_set, reader);
    context.pop();

    return psi;
}

fn decodeHashSet(context: *DecodingContext, set: anytype, reader: anytype) !void {
    const len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read set length: {s}", .{@errorName(err)});
    };

    var i: usize = 0;
    while (i < len) : (i += 1) {
        try context.push(.{ .array_index = i });

        var hash: [32]u8 = undefined;
        reader.readNoEof(&hash) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read hash: {s}", .{@errorName(err)});
        };

        set.put(hash, {}) catch |err| {
            return context.makeError(error.OutOfMemory, "failed to insert hash into set: {s}", .{@errorName(err)});
        };

        context.pop();
    }
}

test "decode psi - empty state" {
    const allocator = testing.allocator;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.append(0); // good_set
    try buffer.append(0); // bad_set
    try buffer.append(0); // wonky_set
    try buffer.append(0); // punish_set

    var fbs = std.io.fixedBufferStream(buffer.items);
    var psi = try decode(allocator, &context, fbs.reader());
    defer psi.deinit();

    try testing.expectEqual(@as(usize, 0), psi.good_set.count());
    try testing.expectEqual(@as(usize, 0), psi.bad_set.count());
    try testing.expectEqual(@as(usize, 0), psi.wonky_set.count());
    try testing.expectEqual(@as(usize, 0), psi.punish_set.count());
}

test "decode psi - with entries" {
    const allocator = testing.allocator;

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.append(1);
    try buffer.appendSlice(&[_]u8{1} ** 32);

    try buffer.append(2);
    try buffer.appendSlice(&[_]u8{2} ** 32);
    try buffer.appendSlice(&[_]u8{3} ** 32);

    try buffer.append(0);

    try buffer.append(1);
    try buffer.appendSlice(&[_]u8{4} ** 32);

    var fbs = std.io.fixedBufferStream(buffer.items);
    var psi = try decode(allocator, &context, fbs.reader());
    defer psi.deinit();

    try testing.expectEqual(@as(usize, 1), psi.good_set.count());
    try testing.expect(psi.good_set.contains([_]u8{1} ** 32));

    try testing.expectEqual(@as(usize, 2), psi.bad_set.count());
    try testing.expect(psi.bad_set.contains([_]u8{2} ** 32));
    try testing.expect(psi.bad_set.contains([_]u8{3} ** 32));

    try testing.expectEqual(@as(usize, 0), psi.wonky_set.count());

    try testing.expectEqual(@as(usize, 1), psi.punish_set.count());
    try testing.expect(psi.punish_set.contains([_]u8{4} ** 32));
}

test "decode psi - insufficient data" {
    const allocator = testing.allocator;

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try buffer.writer().writeByte(0xFF); // Invalid varint
        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try buffer.append(1); // One hash
        try buffer.appendSlice(&[_]u8{1} ** 16); // Only half hash

        var fbs = std.io.fixedBufferStream(buffer.items);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }
}

test "decode psi - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/psi.zig");

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var original = Psi.init(allocator);
    defer original.deinit();

    try original.good_set.put([_]u8{1} ** 32, {});
    try original.bad_set.put([_]u8{2} ** 32, {});
    try original.bad_set.put([_]u8{3} ** 32, {});
    try original.wonky_set.put([_]u8{4} ** 32, {});
    try original.punish_set.put([_]u8{5} ** 32, {});

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(&original, buffer.writer());

    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(allocator, &context, fbs.reader());
    defer decoded.deinit();

    try testing.expectEqual(original.good_set.count(), decoded.good_set.count());
    try testing.expectEqual(original.bad_set.count(), decoded.bad_set.count());
    try testing.expectEqual(original.wonky_set.count(), decoded.wonky_set.count());
    try testing.expectEqual(original.punish_set.count(), decoded.punish_set.count());

    for (original.good_set.keys()) |key| {
        try testing.expect(decoded.good_set.contains(key));
    }

    for (original.bad_set.keys()) |key| {
        try testing.expect(decoded.bad_set.contains(key));
    }

    for (original.wonky_set.keys()) |key| {
        try testing.expect(decoded.wonky_set.contains(key));
    }

    for (original.punish_set.keys()) |key| {
        try testing.expect(decoded.punish_set.contains(key));
    }
}
