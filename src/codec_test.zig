const std = @import("std");
const testing = std.testing;

const codec = @import("codec.zig");
const codec_test = @import("tests/vectors/codec.zig");

const convert = @import("tests/convert/codec.zig");

const types = @import("types.zig");

/// The Tiny PARAMS as they are defined in the ASN
const TINY_PARAMS = types.CodecParams{
    .validators = 6,
    .epoch_length = 12,
    .cores_count = 2,
    .validators_super_majority = 5,
    .avail_bitfield_bytes = 1,
};

/// Helper function to decode and compare test vectors
fn testDecodeAndCompare(comptime T: type, file_path: []const u8) !void {
    const allocator = std.testing.allocator;

    const vector = try codec_test.CodecTestVector(codec_test.types.Header).build_from(allocator, file_path);
    defer vector.deinit();

    var decoded = try codec.deserialize(
        T,
        TINY_PARAMS,
        allocator,
        vector.binary,
    );
    defer decoded.deinit();

    const expected = try convert.convertHeader(allocator, vector.expected.value);
    defer convert.generic.free(allocator, expected);

    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "codec: decode header-0" {
    try testDecodeAndCompare(types.Header, "src/tests/vectors/codec/codec/data/header_0.json");
}

test "codec.active: decode header-1" {
    try testDecodeAndCompare(types.Header, "src/tests/vectors/codec/codec/data/header_1.json");
}
