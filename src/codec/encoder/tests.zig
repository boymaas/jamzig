const std = @import("std");
const encoder = @import("../encoder.zig");
const codec_utils = @import("../util.zig");

const encodeFixedLengthInteger = encoder.encodeFixedLengthInteger;

test "codec.encoder: encodeFixedLengthInteger - u8 (edge case: 0)" {
    var encoded8: [1]u8 = undefined;
    encodeFixedLengthInteger(1, @as(u8, 0), &encoded8);
    const expected8: [1]u8 = [_]u8{0x00};
    try std.testing.expectEqualSlices(u8, &expected8, &encoded8);
}

test "codec.encoder: encodeFixedLengthInteger - u16 (max value)" {
    var encoded16: [2]u8 = undefined;
    encodeFixedLengthInteger(2, @as(u16, 0xFFFF), &encoded16);
    const expected16: [2]u8 = [_]u8{ 0xFF, 0xFF };
    try std.testing.expectEqualSlices(u8, &expected16, &encoded16);
}
test "codec.encoder: encodeFixedLengthInteger - u24" {
    var encoded24: [3]u8 = undefined;
    encodeFixedLengthInteger(3, @as(u24, 0x123456), &encoded24);
    const expected24: [3]u8 = [_]u8{ 0x56, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected24, &encoded24);
}

test "codec.encoder: encodeFixedLengthInteger - u32" {
    var encoded32: [4]u8 = undefined;
    encodeFixedLengthInteger(4, @as(u32, 0x12345678), &encoded32);
    const expected32: [4]u8 = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected32, &encoded32);
}

test "codec.encoder: encodeFixedLengthInteger - u64" {
    var encoded64: [8]u8 = undefined;
    encodeFixedLengthInteger(8, @as(u64, 0x123456789ABCDEF0), &encoded64);
    const expected64: [8]u8 = [_]u8{ 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected64, &encoded64);
}

// test "codec.encoder: encodeFixedLengthInteger - u128" {
//     const encoded128: [16]u8 = encodeFixedLengthInteger(@as(u128, 0x123456789ABCDEF0123456789ABCDEF0));
//     const expected128: [16]u8 = [_]u8{ 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 };
//     try std.testing.expectEqualSlices(u8, &expected128, &encoded128);
// }

// findEncodingLength tests

const findEncodingLength = codec_utils.findEncodingLength;

test "codec.encoder: findEncodingLength - u8 values" {
    try std.testing.expectEqual(@as(?u8, null), findEncodingLength(@as(u8, 0)));
    for (1..128) |i| {
        try std.testing.expectEqual(@as(?u8, 0), findEncodingLength(@as(u8, @intCast(i))));
    }
    for (128..256) |i| {
        try std.testing.expectEqual(@as(?u8, 1), findEncodingLength(@as(u8, @intCast(i))));
    }
}

test "codec.encoder: findEncodingLength - u16 values" {
    try std.testing.expectEqual(@as(?u8, null), findEncodingLength(@as(u16, 0)));

    try std.testing.expectEqual(@as(?u8, 0), findEncodingLength(@as(u16, 127)));
    try std.testing.expectEqual(@as(?u8, 1), findEncodingLength(@as(u16, 128)));

    try std.testing.expectEqual(@as(?u8, 1), findEncodingLength(@as(u16, 256)));
    try std.testing.expectEqual(@as(?u8, 1), findEncodingLength(@as(u16, 16383)));
    try std.testing.expectEqual(@as(?u8, 2), findEncodingLength(@as(u16, 16384)));
}

test "codec.encoder: findEncodingLength - u32 values" {
    try std.testing.expectEqual(@as(?u8, 2), findEncodingLength(@as(u32, 65536)));
    try std.testing.expectEqual(@as(?u8, 3), findEncodingLength(@as(u32, 2097152)));
    try std.testing.expectEqual(@as(?u8, 4), findEncodingLength(@as(u32, 268435456)));
}

test "codec.encoder: findEncodingLength - u64 values" {
    try std.testing.expectEqual(@as(?u8, 4), findEncodingLength(@as(u64, 4294967296)));
    try std.testing.expectEqual(@as(?u8, 5), findEncodingLength(@as(u64, 34359738368)));

    try std.testing.expectEqual(@as(?u8, 5), findEncodingLength(@as(u64, 4398046511103)));
    try std.testing.expectEqual(@as(?u8, 6), findEncodingLength(@as(u64, 4398046511104)));

    try std.testing.expectEqual(@as(?u8, 6), findEncodingLength(@as(u64, 562949953421311)));
    try std.testing.expectEqual(@as(?u8, 7), findEncodingLength(@as(u64, 562949953421312)));

    try std.testing.expectEqual(@as(?u8, 7), findEncodingLength(@as(u64, 72057594037927935)));
    try std.testing.expectEqual(@as(?u8, null), findEncodingLength(@as(u64, 72057594037927936)));

    try std.testing.expectEqual(@as(?u8, null), findEncodingLength(@as(u64, std.math.maxInt(u64))));
}

const encodeInteger = encoder.encodeInteger;

test "codec.encoder: encode test" {
    const result_100 = encodeInteger(@as(u8, 100));
    try std.testing.expectEqualSlices(u8, &[_]u8{100}, result_100.as_slice());

    const result_128 = encodeInteger(@as(u8, 128));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80 }, result_128.as_slice());

    const result_large = encodeInteger(@as(u64, 562949953421312));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 }, result_large.as_slice());

    const result_max = encodeInteger(std.math.maxInt(u64));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, result_max.as_slice());
}

test "codec.encoder: encodeInteger - u8 (0)" {
    const result = encodeInteger(@as(u8, 0));
    try std.testing.expectEqual(@as(u8, 1), result.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, result.as_slice());
}

test "codec.encoder: encodeInteger - u8 (10)" {
    const result = encodeInteger(@as(u8, 10));
    try std.testing.expectEqual(@as(u8, 1), result.len);
}

test "codec.encoder: encodeInteger - u8 (127)" {
    const result = encodeInteger(@as(u8, 127));
    try std.testing.expectEqual(@as(u8, 1), result.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7F}, result.data[0..1]);
}

test "codec.encoder: encodeInteger - u8 (128)" {
    const result = encodeInteger(@as(u8, 128));
    try std.testing.expectEqual(@as(u8, 2), result.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80 }, result.data[0..2]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80 }, result.as_slice());
}
