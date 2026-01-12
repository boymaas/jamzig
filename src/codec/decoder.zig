const std = @import("std");
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const util = @import("util.zig");

pub fn decodeFixedLengthInteger(comptime T: type, buffer: []const u8) T {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len <= @sizeOf(T));

    var result: T = 0;
    for (buffer, 0..) |byte, i| {
        result |= @as(T, byte) << @intCast(i * constants.BYTE_SHIFT);
    }
    return result;
}

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

pub fn decodeInteger(buffer: []const u8) !DecodeResult {
    if (buffer.len == 0) {
        return errors.DecodingError.EmptyBuffer;
    }

    const first_byte = buffer[0];

    if (first_byte == 0) {
        return DecodeResult{ .value = 0, .bytes_read = 1 };
    }

    if (first_byte < constants.SINGLE_BYTE_MAX) {
        return DecodeResult{ .value = first_byte, .bytes_read = 1 };
    }

    if (first_byte == constants.EIGHT_BYTE_MARKER) {
        if (buffer.len < 9) {
            return errors.DecodingError.InsufficientData;
        }
        return DecodeResult{
            .value = decodeFixedLengthInteger(u64, buffer[1..9]),
            .bytes_read = 9,
        };
    }

    const dl = try util.decodePrefixByte(first_byte);

    if (buffer.len < dl.l + 1) {
        return errors.DecodingError.InsufficientData;
    }

    const remainder = decodeFixedLengthInteger(u64, buffer[1 .. dl.l + 1]);

    return DecodeResult{
        .value = remainder + dl.integer_multiple,
        .bytes_read = dl.l + 1,
    };
}
