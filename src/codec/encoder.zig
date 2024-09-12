const std = @import("std");

/// (271) Function to encode an integer into a specified number of octets in
/// little-endian format
pub fn encodeFixedLengthInteger(l: usize, x: u64, buffer: []u8) void {
    std.debug.assert(l > 0);
    std.debug.assert(buffer.len >= l);

    if (l == 1) {
        buffer[0] = @intCast(x & 0xff);
        return;
    }

    var value: u64 = x;
    var i: usize = 0;

    while (i < l) : (i += 1) {
        const masked_value = value & 0xff;

        buffer[i] = @intCast(masked_value);
        value >>= 8;
    }
}

/// Encoding result as specified in the encoding section of the gray paper
/// can hold up to 9 bytes of data including the prefix, allowing it to store
/// values up to 2^64.
pub const EncodingResult = struct {
    data: [9]u8,
    len: u8,

    pub fn build(prefix: ?u8, init_data: []const u8) @This() {
        var self: EncodingResult = .{
            .len = undefined,
            .data = undefined,
        };
        if (prefix) |pre| {
            self.data[0] = pre;
            std.mem.copyForwards(u8, self.data[1..], init_data);
            self.len = @intCast(init_data.len + 1);
        } else {
            std.mem.copyForwards(u8, &self.data, init_data);
            self.len = @intCast(init_data.len);
        }
        return self;
    }

    pub fn as_slice(self: *const @This()) []const u8 {
        return self.data[0..@intCast(self.len)];
    }
};

/// (272) Function to encode an integer (0 to 2^64) into a variable-length.
/// Will return an `EncodingResult` with the possible outcomes. This function will mainly be used
/// to store the length prefixes.
const find_l = @import("util.zig").find_l;
const encode_l = @import("util.zig").encode_l;
pub fn encodeInteger(x: u64) EncodingResult {
    if (x == 0) {
        return EncodingResult.build(null, &[_]u8{0});
    } else if (x < 0x80) {
        // optimize the case where the value is less than 128
        return EncodingResult.build(@intCast(x), &[_]u8{});
    } else if (find_l(x)) |l| {
        const prefix = encode_l(x, l);
        if (l == 0) {
            // If `l` is 0, the value is stored in the prefix to save space during encoding.
            return EncodingResult.build(prefix, &[_]u8{});
        } else {
            // In this case, we need to store the length and pack the value
            // of the remainder at the end.
            var data: [8]u8 = undefined;
            encodeFixedLengthInteger(l, x % (@as(u64, 1) << @intCast(8 * l)), &data);
            return EncodingResult.build(prefix, data[0..l]);
        }
    } else {
        // When `l` is not found, we need to encode the value as a fixed-length integer.
        var data: [8]u8 = undefined;
        encodeFixedLengthInteger(8, x, &data);

        return EncodingResult.build(0xFF, &data);
    }
}

comptime {
    _ = @import("encoder/tests.zig");
}
