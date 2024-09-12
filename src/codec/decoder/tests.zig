const std = @import("std");
const decoder = @import("../decoder.zig");
const codec_utils = @import("../util.zig");

// decodeFixedLengthInteger tests

const decodeFixedLengthInteger = decoder.decodeFixedLengthInteger;

test "codec.decoder: decodeFixedLengthInteger - u8 (edge case: 0)" {
    const decoded8 = decodeFixedLengthInteger(u8, &[_]u8{0x00});
    try std.testing.expectEqual(@as(u8, 0), decoded8);
}

test "codec.decoder: decodeFixedLengthInteger - u16 (max value)" {
    const decoded16 = decodeFixedLengthInteger(u16, &[_]u8{ 0xFF, 0xFF });
    try std.testing.expectEqual(@as(u16, 0xFFFF), decoded16);
}

test "codec.decoder: decodeFixedLengthInteger - u24" {
    const decoded24 = decodeFixedLengthInteger(u32, &[_]u8{ 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u32, 0x123456), decoded24);
}

test "codec.decoder: decodeFixedLengthInteger - u32" {
    const decoded32 = decodeFixedLengthInteger(u32, &[_]u8{ 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u32, 0x12345678), decoded32);
}

test "codec.decoder: decodeFixedLengthInteger - u64" {
    const decoded64 = decodeFixedLengthInteger(u64, &[_]u8{ 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), decoded64);
}

// decodeInteger tests

const decodeInteger = decoder.decodeInteger;

test "codec.decoder: decodeInteger - u8 (0)" {
    const result = try decodeInteger(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "codec.decoder: decodeInteger - u8 (10)" {
    const result = try decodeInteger(&[_]u8{10});
    try std.testing.expectEqual(@as(u64, 10), result);
}

test "codec.decoder: decodeInteger - u8 (127)" {
    const result = try decodeInteger(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(u64, 127), result);
}

test "codec.decoder: decodeInteger - u8 (128)" {
    const result = try decodeInteger(&[_]u8{ 0x80, 0x80 });
    try std.testing.expectEqual(@as(u64, 128), result);
}

test "codec.decoder: decodeInteger - large value" {
    const result = try decodeInteger(&[_]u8{ 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 });
    try std.testing.expectEqual(@as(u64, 562949953421312), result);
}

test "codec.decoder: decodeInteger - max u64" {
    const result = try decodeInteger(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try std.testing.expectEqual(std.math.maxInt(u64), result);
}

test "codec.decoder: decodeInteger - error cases" {
    try std.testing.expectError(error.EmptyBuffer, decodeInteger(&[_]u8{}));
    try std.testing.expectError(error.InsufficientData, decodeInteger(&[_]u8{0x80}));
    try std.testing.expectError(error.InsufficientData, decodeInteger(&[_]u8{0xFF}));
}
