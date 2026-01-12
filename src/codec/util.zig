const std = @import("std");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

/// Finds the encoding length parameter 'l' for a given value according to variable-length encoding rules
///
/// The bounds for each l value are:
/// - l=0: 1 <= x < 128
/// - l=1: 128 <= x < 16,384
/// - l=2: 16,384 <= x < 2,097,152
/// - l=3: 2,097,152 <= x < 268,435,456
/// - l=4: 268,435,456 <= x < 34,359,738,368
/// - l=5: 34,359,738,368 <= x < 4,398,046,511,104
/// - l=6: 4,398,046,511,104 <= x < 562,949,953,421,312
/// - l=7: 562,949,953,421,312 <= x < 72,057,594,037,927,936
///
/// Returns: The encoding length parameter, or null if x is too large
pub fn findEncodingLength(x: u64) ?u8 {
    var l: u8 = 0;
    while (l <= constants.MAX_L_VALUE) : (l += 1) {
        const lower_bound: u64 = @as(u64, 1) << @intCast(constants.ENCODING_BIT_SHIFT * l);
        const upper_bound: u64 = @as(u64, 1) << @intCast(constants.ENCODING_BIT_SHIFT * (l + 1));

        if (x >= lower_bound and x < upper_bound) {
            return l;
        }
    }

    return null;
}

/// Builds the prefix byte for a given encoding length
/// Formula: 2^8 - 2^(8-l)
///
/// Parameters:
/// - l: The encoding length (must be 0-7)
///
/// Returns: The prefix byte
pub inline fn buildPrefixByte(l: u8) u8 {
    return ~(@as(u8, 0xFF) >> @intCast(l));
}

/// Encodes the length parameter and value quotient into a single prefix byte
///
/// Parameters:
/// - x: The value being encoded
/// - l: The encoding length parameter
///
/// Returns: The encoded prefix byte
pub fn encodePrefixWithQuotient(x: u64, l: u8) u8 {
    const prefix: u8 = buildPrefixByte(l);
    return prefix + @as(u8, @truncate((x >> @intCast(constants.BYTE_SHIFT * l))));
}

/// Result of prefix decoding
pub const PrefixDecodeResult = struct {
    /// The integer multiple component (quotient * 2^(8l))
    integer_multiple: u64,
    /// The encoding length parameter
    l: u8,
};

/// Decodes a prefix byte to extract the encoding length and integer multiple
///
/// Parameters:
/// - e: The encoded prefix byte
///
/// Returns: PrefixDecodeResult with the decoded components
pub fn decodePrefixByte(e: u8) !PrefixDecodeResult {
    const l: u8 = @clz(~e);
    if (l > constants.MAX_L_VALUE) {
        return errors.DecodingError.InvalidFormat;
    }

    const prefix: u8 = buildPrefixByte(l);
    const quotient = e - prefix;
    const integer_multiple: u64 = @as(u64, quotient) << @intCast(constants.BYTE_SHIFT * l);

    return PrefixDecodeResult{ .integer_multiple = integer_multiple, .l = l };
}
