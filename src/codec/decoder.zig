const std = @import("std");

/// (271) Reverse function
/// Decodes a fixed-length integer from a slice of bytes in little-endian format
pub fn decodeFixedLengthInteger(comptime T: type, buffer: []const u8) T {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len <= @sizeOf(T));

    var result: T = 0;
    for (buffer, 0..) |byte, i| {
        result |= @as(T, byte) << @intCast(i * 8);
    }
    return result;
}

/// (272) Function to decode an integer (0 to 2^64) from a variable-length
/// encoding as described in the gray paper.
const util = @import("util.zig");
pub fn decodeInteger(buffer: []const u8) !u64 {
    if (buffer.len == 0) {
        return error.EmptyBuffer;
    }

    const first_byte = buffer[0];

    if (first_byte == 0) {
        return 0;
    }

    if (first_byte < 0x80) {
        return first_byte;
    }

    if (first_byte == 0xff) {
        // Special case: 8-byte fixed-length integer
        if (buffer.len < 9) {
            return error.InsufficientData;
        }
        return decodeFixedLengthInteger(u64, buffer[1..9]);
    }

    const dl = util.decode_prefix(first_byte);

    if (buffer.len < dl.l + 1) {
        return error.InsufficientData;
    }

    // now get the value out of it
    const remainder = decodeFixedLengthInteger(u64, buffer[1 .. dl.l + 1]);

    return remainder + dl.integer_multiple;
}
