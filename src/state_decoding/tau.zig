const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const Tau = types.TimeSlot;

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Tau {
    _ = allocator;

    try context.push(.{ .component = "tau" });
    defer context.pop();
    
    const value = reader.readInt(u32, .little) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read timeslot value: {s}", .{@errorName(err)});
    };
    
    return value;
}

test "decode tau - valid data" {
    const allocator = testing.allocator;

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = [_]u8{ 42, 0, 0, 0 };
        var fbs = std.io.fixedBufferStream(&buffer);
        const tau = try decode(allocator, &context, fbs.reader());
        try testing.expectEqual(@as(u32, 42), tau);
    }

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = [_]u8{ 0xff, 0xff, 0xff, 0xff };
        var fbs = std.io.fixedBufferStream(&buffer);
        const tau = try decode(allocator, &context, fbs.reader());
        try testing.expectEqual(@as(u32, 0xffffffff), tau);
    }

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer = [_]u8{ 0, 0, 0, 0 };
        var fbs = std.io.fixedBufferStream(&buffer);
        const tau = try decode(allocator, &context, fbs.reader());
        try testing.expectEqual(@as(u32, 0), tau);
    }
}

test "decode tau - invalid data" {
    const allocator = testing.allocator;

    {
        var context = DecodingContext.init(allocator);
        defer context.deinit();

        var buffer = [_]u8{ 42, 0, 0 };
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(allocator, &context, fbs.reader()));
    }
}

test "decode tau - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/tau.zig");

    const test_values = [_]u32{ 0, 1, 42, 0xffff, 0xffffffff };

    for (test_values) |expected| {
        var context = DecodingContext.init(allocator);
        defer context.deinit();
        
        var buffer: [4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);

        try encoder.encode(expected, fbs.writer());

        fbs.pos = 0;

        const decoded = try decode(allocator, &context, fbs.reader());

        try testing.expectEqual(expected, decoded);
    }
}
