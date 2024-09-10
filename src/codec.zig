const std = @import("std");

pub fn deserialize(comptime T: type, data: []u8) !T {
    _ = data;
    return error.NotImplemented;
}

/// (271) Function to encode an integer into a specified number of octets in
/// little-endian format
fn encodeFixedLengthInteger(x: anytype) [@sizeOf(@TypeOf(x))]u8 {
    const L = @sizeOf(@TypeOf(x)); // Determine the size of the value in bytes
    return encodeFixedLengthIntegerWithSize(L, x);
}

fn encodeFixedLengthIntegerWithSize(comptime L: usize, x: anytype) [L]u8 {
    var result: [L]u8 = undefined;

    if (L == 1) {
        result[0] = @intCast(x);
        return result;
    }

    var value: @TypeOf(x) = x;
    var i: usize = 0;

    while (i < L) : (i += 1) {
        result[i] = @intCast(value & 0xff);
        value >>= 8;
    }

    return result;
}

test "codec: encodeFixedLengthInteger - u24" {
    const encoded24: [4]u8 = encodeFixedLengthInteger(@as(u24, 0x123456));
    const expected24: [4]u8 = [_]u8{ 0x56, 0x34, 0x12, 0x00 };
    try std.testing.expectEqualSlices(u8, &expected24, &encoded24);
}

test "codec: encodeFixedLengthInteger - u8 (edge case: 0)" {
    const encoded8: [1]u8 = encodeFixedLengthInteger(@as(u8, 0));
    const expected8: [1]u8 = [_]u8{0x00};
    try std.testing.expectEqualSlices(u8, &expected8, &encoded8);
}

test "codec: encodeFixedLengthInteger - u16 (max value)" {
    const encoded16: [2]u8 = encodeFixedLengthInteger(@as(u16, 0xFFFF));
    const expected16: [2]u8 = [_]u8{ 0xFF, 0xFF };
    try std.testing.expectEqualSlices(u8, &expected16, &encoded16);
}

test "codec: encodeFixedLengthInteger - u32" {
    const encoded32: [4]u8 = encodeFixedLengthInteger(@as(u32, 0x12345678));
    const expected32: [4]u8 = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected32, &encoded32);
}

test "codec: encodeFixedLengthInteger - u64" {
    const encoded64: [8]u8 = encodeFixedLengthInteger(@as(u64, 0x123456789ABCDEF0));
    const expected64: [8]u8 = [_]u8{ 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected64, &encoded64);
}

test "codec: encodeFixedLengthInteger - u128" {
    const encoded128: [16]u8 = encodeFixedLengthInteger(@as(u128, 0x123456789ABCDEF0123456789ABCDEF0));
    const expected128: [16]u8 = [_]u8{ 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected128, &encoded128);
}

/// (272) Function to encode an integer (0 to 2^64 - 1) into a variable-length
/// sequence (1 to 9 bytes)
fn encodeGeneralInteger(x: u64, allocator: *std.mem.Allocator) ![]u8 {
    if (x == 0) {
        return allocator.alloc(u8, 1); // return [0] as the encoded value
    }

    var l: u8 = 1;
    while ((x >> (7 * l)) != 0 and l < 9) : (l += 1) {}

    if (l == 9) {
        return try encodeFixedLengthInteger(8, x, allocator); // special case for 64-bit integers
    } else {
        const prefix = 0x80 - l;
        const encoded_value = try encodeFixedLengthInteger(l, x, allocator);
        const result = try allocator.alloc(u8, 1 + encoded_value.len);
        result[0] = @intCast(prefix);
        std.mem.copy(u8, result[1..], encoded_value);
        return result;
    }
}
