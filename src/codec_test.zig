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
fn testDecodeAndCompare(comptime DomainType: type, comptime VectorType: type, file_path: []const u8) !void {
    const allocator = std.testing.allocator;

    const vector = try codec_test.CodecTestVector(VectorType).build_from(allocator, file_path);
    defer vector.deinit();

    var decoded = try codec.deserialize(
        DomainType,
        TINY_PARAMS,
        allocator,
        vector.binary,
    );
    defer decoded.deinit();

    const expected: DomainType = try convert.convert(VectorType, DomainType, allocator, vector.expected.value);
    defer convert.generic.free(allocator, expected);

    try std.testing.expectEqualDeep(expected, decoded.value);
}

test "codec: decode header-0" {
    try testDecodeAndCompare(types.Header, codec_test.types.Header, "src/tests/vectors/codec/codec/data/header_0.json");
}

test "codec: decode header-1" {
    try testDecodeAndCompare(types.Header, codec_test.types.Header, "src/tests/vectors/codec/codec/data/header_1.json");
}

test "codec.active: decode extrinsic" {
    try testDecodeAndCompare(types.Extrinsic, codec_test.types.Extrinsic, "src/tests/vectors/codec/codec/data/extrinsic.json");
}
