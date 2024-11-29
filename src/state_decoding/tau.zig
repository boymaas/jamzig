const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const DecodingError = @import("../state_decoding.zig").DecodingError;

const Tau = types.TimeSlot;

/// Decodes tau (τ) from raw bytes.
/// Tau represents the current timeslot and is encoded as a little-endian u32
pub fn decode(reader: anytype) !Tau {
    return try reader.readInt(u32, .little);
}

test "decode tau - valid data" {
    // Test simple value
    {
        var buffer = [_]u8{ 42, 0, 0, 0 };
        var fbs = std.io.fixedBufferStream(&buffer);
        const tau = try decode(fbs.reader());
        try testing.expectEqual(@as(u32, 42), tau);
    }

    // Test max value
    {
        var buffer = [_]u8{ 0xff, 0xff, 0xff, 0xff };
        var fbs = std.io.fixedBufferStream(&buffer);
        const tau = try decode(fbs.reader());
        try testing.expectEqual(@as(u32, 0xffffffff), tau);
    }

    // Test zero value
    {
        var buffer = [_]u8{ 0, 0, 0, 0 };
        var fbs = std.io.fixedBufferStream(&buffer);
        const tau = try decode(fbs.reader());
        try testing.expectEqual(@as(u32, 0), tau);
    }
}

test "decode tau - invalid data" {
    // Test insufficient data
    {
        var buffer = [_]u8{ 42, 0, 0 }; // Only 3 bytes
        var fbs = std.io.fixedBufferStream(&buffer);
        try testing.expectError(error.EndOfStream, decode(fbs.reader()));
    }
}

test "decode tau - roundtrip" {
    const encoder = @import("../state_encoding/tau.zig");

    // Test various values
    const test_values = [_]u32{ 0, 1, 42, 0xffff, 0xffffffff };

    for (test_values) |expected| {
        var buffer: [4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);

        // Encode
        try encoder.encode(expected, fbs.writer());

        // Reset buffer position
        fbs.pos = 0;

        // Decode
        const decoded = try decode(fbs.reader());

        // Verify
        try testing.expectEqual(expected, decoded);
    }
}
