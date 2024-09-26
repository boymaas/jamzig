const std = @import("std");

const MAX_SIZE_IN_BYTES: usize = 4;

fn buildBuffer(bytes: []const u8) [MAX_SIZE_IN_BYTES]u8 {
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

// Rest of the code remains the same...

fn getUnsigned(bytes: []const u8) u32 {
    const buffer = buildBuffer(bytes);
    return std.mem.readInt(u32, &buffer, .little);
}

fn getSigned(bytes: []const u8) i32 {
    return @bitCast(getUnsigned(bytes));
}

test "pvm:args:immediate - edge cases and conversions" {
    const testing = std.testing;
    const testCases = [_]struct {
        input: []const u8,
        expectedSigned: i32,
        expectedUnsigned: u32,
        expectedBytes: [4]u8,
    }{
        // Empty input
        .{
            .input = &[_]u8{},
            .expectedSigned = 0,
            .expectedUnsigned = 0,
            .expectedBytes = .{ 0, 0, 0, 0 },
        },
        // Single byte positive
        .{
            .input = &[_]u8{0x42},
            .expectedSigned = 0x42,
            .expectedUnsigned = 0x42,
            .expectedBytes = .{ 0x42, 0, 0, 0 },
        },
        // Single byte negative
        .{
            .input = &[_]u8{0xA7},
            .expectedSigned = -89,
            .expectedUnsigned = 0xFFFFFFA7,
            .expectedBytes = .{ 0xA7, 0xFF, 0xFF, 0xFF },
        },
        // Two bytes positive
        .{
            .input = &[_]u8{ 0x34, 0x12 },
            .expectedSigned = 0x1234,
            .expectedUnsigned = 0x1234,
            .expectedBytes = .{ 0x34, 0x12, 0, 0 },
        },
        // Two bytes negative
        .{
            .input = &[_]u8{ 0xCD, 0xAB },
            .expectedSigned = -21555,
            .expectedUnsigned = 0xFFFFABCD,
            .expectedBytes = .{ 0xCD, 0xAB, 0xFF, 0xFF },
        },
        // Three bytes positive
        .{
            .input = &[_]u8{ 0x78, 0x56, 0x34 },
            .expectedSigned = 0x345678,
            .expectedUnsigned = 0x345678,
            .expectedBytes = .{ 0x78, 0x56, 0x34, 0 },
        },
        // Three bytes negative
        .{
            .input = &[_]u8{ 0xBC, 0x9A, 0xF1 },
            .expectedSigned = -943428,
            .expectedUnsigned = 0xFFF19ABC,
            .expectedBytes = .{ 0xBC, 0x9A, 0xF1, 0xFF },
        },
        // Four bytes positive
        .{
            .input = &[_]u8{ 0xEF, 0xCD, 0xAB, 0x01 },
            .expectedSigned = 0x01ABCDEF,
            .expectedUnsigned = 0x01ABCDEF,
            .expectedBytes = .{ 0xEF, 0xCD, 0xAB, 0x01 },
        },
        // Four bytes negative
        .{
            .input = &[_]u8{ 0x23, 0x45, 0x67, 0x89 },
            .expectedSigned = -1989720797,
            .expectedUnsigned = 0x89674523,
            .expectedBytes = .{ 0x23, 0x45, 0x67, 0x89 },
        },
        // Max positive value
        .{
            .input = &[_]u8{ 0xFF, 0xFF, 0xFF, 0x7F },
            .expectedSigned = 0x7FFFFFFF,
            .expectedUnsigned = 0x7FFFFFFF,
            .expectedBytes = .{ 0xFF, 0xFF, 0xFF, 0x7F },
        },
        // Max negative value
        .{
            .input = &[_]u8{ 0x00, 0x00, 0x00, 0x80 },
            .expectedSigned = -0x80000000,
            .expectedUnsigned = 0x80000000,
            .expectedBytes = .{ 0x00, 0x00, 0x00, 0x80 },
        },
        // More than 4 bytes (should truncate)
        .{
            .input = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 },
            .expectedSigned = 0x44332211,
            .expectedUnsigned = 0x44332211,
            .expectedBytes = .{ 0x11, 0x22, 0x33, 0x44 },
        },
    };

    for (testCases) |tc| {
        const buffer = buildBuffer(tc.input);
        try testing.expectEqual(tc.expectedSigned, getSigned(&buffer));
        try testing.expectEqual(tc.expectedUnsigned, getUnsigned(&buffer));
        try testing.expectEqualSlices(u8, &tc.expectedBytes, &buffer);
    }
}
