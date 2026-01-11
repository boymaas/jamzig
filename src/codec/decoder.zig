const std = @import("std");
const constants = @import("constants.zig");
const errors = @import("errors.zig");
const util = @import("util.zig");

/// Decodes a fixed-length integer from bytes in little-endian format (eq. 271 reverse)
///
/// Parameters:
/// - T: The integer type to decode into
/// - buffer: Input buffer containing the encoded bytes
///
/// Returns: The decoded integer value
pub fn decodeFixedLengthInteger(comptime T: type, buffer: []const u8) T {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len <= @sizeOf(T));

    var result: T = 0;
    for (buffer, 0..) |byte, i| {
        result |= @as(T, byte) << @intCast(i * constants.BYTE_SHIFT);
    }
    return result;
}

/// Decodes an integer (0 to 2^64) from variable-length encoding (eq. 272)
/// as described in the graypaper.
/// Result of variable-length integer decoding
pub const DecodeResult = struct {
    /// The decoded integer value
    value: u64,
    /// Number of bytes consumed from the input buffer
    bytes_read: usize,
};

/// Decodes a variable-length integer from a buffer
///
/// Parameters:
/// - buffer: Input buffer containing the encoded integer
///
/// Returns: DecodeResult with the value and bytes consumed
/// Errors: EmptyBuffer, InsufficientData
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
