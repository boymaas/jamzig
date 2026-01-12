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

        try std.testing.expect(encoded.len > 0);
        try std.testing.expect(encoded.len <= 9);

        const decoded = try decoder.decodeInteger(encoded.as_slice());

        try std.testing.expectEqual(test_case.value, decoded.value);
    }
}
