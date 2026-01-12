const std = @import("std");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

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

pub inline fn buildPrefixByte(l: u8) u8 {
    return ~(@as(u8, 0xFF) >> @intCast(l));
}

pub fn encodePrefixWithQuotient(x: u64, l: u8) u8 {
    const prefix: u8 = buildPrefixByte(l);
    return prefix + @as(u8, @truncate((x >> @intCast(constants.BYTE_SHIFT * l))));
}

pub const PrefixDecodeResult = struct {
    integer_multiple: u64,
    l: u8,
};

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
