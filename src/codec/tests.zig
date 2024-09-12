const std = @import("std");

const encoder = @import("encoder.zig");
const decoder = @import("decoder.zig");

const TestCase = struct {
    value: u64,

    fn generate(prng: std.Random) TestCase {
        const bitsize = prng.intRangeAtMost(u6, 0, 63);
        const mask = if (bitsize == 64) std.math.maxInt(u64) else ((@as(u64, 1) << bitsize) - 1);
        return TestCase{
            .value = prng.int(u64) & mask,
        };
    }
};

test "codec.fuzz: encodeInteger - fuzz test" {
    var random = std.Random.DefaultPrng.init(0);
    const prng = random.random();

    for (0..1_000_000) |_| {
        const test_case = TestCase.generate(prng);
        const encoded = encoder.encodeInteger(test_case.value);

        // Verify that the encoded result is not empty
        try std.testing.expect(encoded.len > 0);

        // Verify that the encoded result is not longer than 9 bytes
        try std.testing.expect(encoded.len <= 9);

        // Decode the encoded value and verify it matches the original
        const decoded = try decoder.decodeInteger(encoded.as_slice());

        // std.debug.print("Original: {}, Encoded: {any}, Decoded: {}\n", .{ test_case.value, encoded.as_slice(), decoded });

        try std.testing.expectEqual(test_case.value, decoded.value);
    }
}
