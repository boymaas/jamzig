const std = @import("std");

// bounds l=0: 1 <= x < 128
// bounds l=1: 128 <= x < 16384
// bounds l=2: 16384 <= x < 2097152
// bounds l=3: 2097152 <= x < 268435456
// bounds l=4: 268435456 <= x < 34359738368
// bounds l=5: 34359738368 <= x < 4398046511104
// bounds l=6: 4398046511104 <= x < 562949953421312
// bounds l=7: 562949953421312 <= x < 72057594037927936
pub fn find_l(x: u64) ?u8 {
    // Iterate over l in the range of 0 to 7 (l in N_8)
    var l: u8 = 0;
    while (l < 8) : (l += 1) {
        const lower_bound: u64 = @as(u64, 1) << @intCast(7 * l); // 2^(7l)
        const upper_bound: u64 = @as(u64, 1) << @intCast(7 * (l + 1)); // 2^(7(l+1))

        // Check if x falls within the range [2^(7l), 2^(7(l+1)))
        if (x >= lower_bound and x < upper_bound) {
            return l; // l is found
        }
    }

    return null;
}

// 2^8 - 2^(8-l)
pub inline fn build_prefix(l: u8) u8 {
    return ~(@as(u8, 0xFF) >> @intCast(l));
}

pub fn encode_l(x: u64, l: u8) u8 {
    const prefix: u8 = build_prefix(l);
    return prefix + @as(u8, @truncate((x >> @intCast(8 * l))));
}

pub fn decode_prefix(e: u8) struct { integer_multiple: u64, l: u8 } {
    const l: u8 = @clz(~e);
    std.debug.assert(l < 8);
    const prefix: u8 = build_prefix(l);
    const quotient = e - prefix;
    const integer_multiple: u64 = @as(u64, quotient) << @intCast(8 * l);
    return .{ .integer_multiple = integer_multiple, .l = l };
}
