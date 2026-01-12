const std = @import("std");
const constants = @import("constants.zig");
const errors = @import("errors.zig");

/// Encodes an integer into a specified number of octets in little-endian format (eq. 271)
///
/// Parameters:
/// - l: Number of octets to encode (must be > 0)
/// - x: The integer value to encode
/// - buffer: Output buffer (must have at least l bytes)
pub fn encodeFixedLengthInteger(l: usize, x: u64, buffer: []u8) void {
    std.debug.assert(l > 0);
    std.debug.assert(buffer.len >= l);

    if (l == 1) {
        buffer[0] = @intCast(x & 0xff);
        return;
    }

    var value: u64 = x;
    for (buffer[0..l]) |*byte| {
        byte.* = @intCast(value & 0xff);
        value >>= constants.BYTE_SHIFT;
    }
}

/// Result of variable-length integer encoding
/// Can hold up to 9 bytes of data including the prefix byte,
/// allowing storage of values up to 2^64 as per graypaper encoding rules.
pub const EncodingResult = struct {
    data: [9]u8,
    len: u8,

    /// Constructs an EncodingResult with optional prefix and data
    ///
    /// Parameters:
    /// - prefix: Optional prefix byte (null if no prefix needed)
    /// - init_data: The encoded data bytes
    pub fn build(prefix: ?u8, init_data: []const u8) EncodingResult {
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

    /// Returns the encoded data as a slice
    pub fn as_slice(self: *const EncodingResult) []const u8 {
        return self.data[0..@intCast(self.len)];
    }
};

/// Encodes an integer (0 to 2^64) into variable-length format (eq. 272)
/// Returns an EncodingResult containing the encoded bytes.
/// This is primarily used for encoding length prefixes in the codec.
const util = @import("util.zig");
pub fn encodeInteger(x: u64) EncodingResult {
    if (x == 0) {
        return EncodingResult.build(null, &[_]u8{0});
    } else if (x < constants.SINGLE_BYTE_MAX) {
        return EncodingResult.build(@intCast(x), &[_]u8{});
    } else if (util.findEncodingLength(x)) |l| {
        const prefix = util.encodePrefixWithQuotient(x, l);
        if (l == 0) {
            return EncodingResult.build(prefix, &[_]u8{});
        } else {
            var data: [8]u8 = undefined;
            encodeFixedLengthInteger(l, x % (@as(u64, 1) << @intCast(constants.BYTE_SHIFT * l)), &data);
            return EncodingResult.build(prefix, data[0..l]);
        }
    } else {
        var data: [8]u8 = undefined;
        encodeFixedLengthInteger(8, x, &data);

        return EncodingResult.build(constants.EIGHT_BYTE_MARKER, &data);
    }
}
