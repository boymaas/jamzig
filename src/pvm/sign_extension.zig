const std = @import("std");

/// Sign extends any integer type (signed or unsigned) to a larger integer type (signed or unsigned).
/// Uses compile-time type information to handle all cases uniformly through signed integer extension.
pub fn signExtend(comptime FromT: type, comptime ToT: type, value: FromT) ToT {
    // Verify at compile time that both types are integers
    comptime {
        if (!(@typeInfo(FromT) == .int and @typeInfo(ToT) == .int)) {
            @compileError("Both types must be integers");
        }
        // Verify target type is larger than source type
        if (@typeInfo(FromT).int.bits > @typeInfo(ToT).int.bits) {
            @compileError("Target type must be larger than source type");
        }
    }

    // Step 1: If input is unsigned, convert it to signed of the same size
    const SignedFromT = std.meta.Int(.signed, @typeInfo(FromT).int.bits);
    const signed_value = if (@typeInfo(FromT).int.signedness == .unsigned)
        @as(SignedFromT, @bitCast(value))
    else
        @as(SignedFromT, value);

    // Step 2: Extend the signed value to the target size
    const SignedToT = std.meta.Int(.signed, @typeInfo(ToT).int.bits);
    const extended_value = @as(SignedToT, @intCast(signed_value));

    // Step 3: If target is unsigned, convert the extended value
    return if (@typeInfo(ToT).int.signedness == .unsigned)
        @bitCast(extended_value)
    else
        @intCast(extended_value);
}

test "signExtend - simplified implementation" {
    const testing = std.testing;

    // From unsigned to signed
    try testing.expectEqual(@as(i16, -1), signExtend(u8, i16, 0xFF));
    try testing.expectEqual(@as(i32, 66), signExtend(u8, i32, 66));

    // From signed to signed
    try testing.expectEqual(@as(i32, -1), signExtend(i8, i32, -1));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), signExtend(i8, u32, -1));
    try testing.expectEqual(@as(u16, 66), signExtend(i8, u16, 66));

    // From unsigned to unsigned (sign-extending)
    try testing.expectEqual(@as(u16, 0xFFFF), signExtend(u8, u16, 0xFF));
    try testing.expectEqual(@as(u16, 0x0042), signExtend(u8, u16, 0x42));

    // From signed to unsigned
    try testing.expectEqual(@as(u16, 0xFFFF), signExtend(i8, u16, -1));
    try testing.expectEqual(@as(u32, 0x00000042), signExtend(i8, u32, 66));

    // Edge cases
    try testing.expectEqual(@as(u16, 0x007F), signExtend(i8, u16, 127)); // Max positive i8
    try testing.expectEqual(@as(u16, 0xFF80), signExtend(i8, u16, -128)); // Min negative i8
    try testing.expectEqual(@as(u32, 0xFFFFFF80), signExtend(u8, u32, 0x80)); // Testing sign bit
}

/// Sign extends any integer type (signed or unsigned) to u64.
/// Takes advantage of comptime type checking to ensure we only work with integers.
pub inline fn signExtendToU64(comptime T: type, value: T) u64 {
    return signExtend(T, u64, value);
}

test "signExtendToU64" {
    const testing = std.testing;

    // Test with unsigned types
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), signExtendToU64(u8, 0xFF)); // -1 as u8
    try testing.expectEqual(@as(u64, 0x0000000000000042), signExtendToU64(u8, 0x42)); // +66 as u8
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), signExtendToU64(u32, 0xFFFFFFFF)); // -1 as u32

    // Test with signed types
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), signExtendToU64(i8, -1));
    try testing.expectEqual(@as(u64, 0x0000000000000042), signExtendToU64(i8, 66));
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), signExtendToU64(i32, -1));

    // Test with 64-bit types
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), signExtendToU64(i64, -1));
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), signExtendToU64(u64, 0xFFFFFFFFFFFFFFFF));
}
