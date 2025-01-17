const std = @import("std");

const MAX_SIZE_IN_BYTES: usize = 8;

fn buildBufferSignExtend(bytes: []const u8) [MAX_SIZE_IN_BYTES]u8 {
    var buffer: [MAX_SIZE_IN_BYTES]u8 = undefined;
    const n = @min(bytes.len, MAX_SIZE_IN_BYTES);

    if (n > 0) {
        @memcpy(buffer[0..n], bytes[0..n]);
        const sign_extend = if (bytes[n - 1] & 0x80 != 0) @as(u8, 0xff) else 0x00;
        @memset(buffer[n..], sign_extend);
    } else {
        @memset(&buffer, 0);
    }

    return buffer;
}

pub fn decodeUnsigned(bytes: []const u8) u64 {
    const buffer = buildBufferSignExtend(bytes);
    return std.mem.readInt(u64, &buffer, .little);
}

pub fn decodeSigned(bytes: []const u8) i64 {
    const buffer = buildBufferSignExtend(bytes);
    return std.mem.readInt(i64, &buffer, .little);
}

pub fn decodeOffset(bytes: []const u8) i32 {
    const buffer = buildBufferSignExtend(bytes);
    return std.mem.readInt(i32, buffer[0..4], .little);
}

test "pvm:args:immediate - empty input" {
    const testing = std.testing;
    const input = &[_]u8{};
    try testing.expectEqual(@as(i64, 0), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0), decodeUnsigned(input));
}

test "pvm:args:immediate - single byte positive" {
    const testing = std.testing;
    const input = &[_]u8{0x42};
    try testing.expectEqual(@as(i64, 0x42), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0x42), decodeUnsigned(input));
}

test "pvm:args:immediate - single byte negative" {
    const testing = std.testing;
    const input = &[_]u8{0xA7};
    try testing.expectEqual(@as(i64, -89), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFA7), decodeUnsigned(input));
}

test "pvm:args:immediate - two bytes positive" {
    const testing = std.testing;
    const input = &[_]u8{ 0x34, 0x12 };
    try testing.expectEqual(@as(i64, 0x1234), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0x1234), decodeUnsigned(input));
}

test "pvm:args:immediate - two bytes negative" {
    const testing = std.testing;
    const input = &[_]u8{ 0xCD, 0xAB };
    try testing.expectEqual(@as(i64, -21555), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFABCD), decodeUnsigned(input));
}

test "pvm:args:immediate - three bytes positive" {
    const testing = std.testing;
    const input = &[_]u8{ 0x78, 0x56, 0x34 };
    try testing.expectEqual(@as(i64, 0x345678), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0x345678), decodeUnsigned(input));
}

test "pvm:args:immediate - three bytes negative" {
    const testing = std.testing;
    const input = &[_]u8{ 0xBC, 0x9A, 0xF1 };
    try testing.expectEqual(@as(i64, -943428), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFF19ABC), decodeUnsigned(input));
}

test "pvm:args:immediate - four bytes positive" {
    const testing = std.testing;
    const input = &[_]u8{ 0xEF, 0xCD, 0xAB, 0x01 };
    try testing.expectEqual(@as(i64, 0x01ABCDEF), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0x01ABCDEF), decodeUnsigned(input));
}

test "pvm:args:immediate - four bytes negative" {
    const testing = std.testing;
    const input = &[_]u8{ 0x23, 0x45, 0x67, 0x89 };
    try testing.expectEqual(@as(i64, -1989720797), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0xFFFFFFFF89674523), decodeUnsigned(input));
}

test "pvm:args:immediate - max positive value" {
    const testing = std.testing;
    const input = &[_]u8{ 0xFF, 0xFF, 0xFF, 0x7F };
    try testing.expectEqual(@as(i64, 0x7FFFFFFF), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0x7FFFFFFF), decodeUnsigned(input));
}

test "pvm:args:immediate - max negative value" {
    const testing = std.testing;
    const input = &[_]u8{ 0x00, 0x00, 0x00, 0x80 };
    try testing.expectEqual(@as(i64, -0x80000000), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0xFFFFFFFF80000000), decodeUnsigned(input));
}

test "pvm:args:immediate - truncate long input" {
    const testing = std.testing;
    const input = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    try testing.expectEqual(@as(i64, 0x44332211), decodeSigned(input));
    try testing.expectEqual(@as(u64, 0x44332211), decodeUnsigned(input));
}
