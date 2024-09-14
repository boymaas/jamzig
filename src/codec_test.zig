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

test "codec: decode extrinsic" {
    try testDecodeAndCompare(types.Extrinsic, codec_test.types.Extrinsic, "src/tests/vectors/codec/codec/data/extrinsic.json");
}

test "codec: decode block" {
    try testDecodeAndCompare(types.Block, codec_test.types.Block, "src/tests/vectors/codec/codec/data/block.json");
}

test "codec: decode assurances_extrinsic" {
    try testDecodeAndCompare(types.AssurancesExtrinsic, codec_test.types.AssurancesExtrinsic, "src/tests/vectors/codec/codec/data/assurances_extrinsic.json");
}

test "codec: decode disputes_extrinsic" {
    try testDecodeAndCompare(types.DisputesExtrinsic, codec_test.types.DisputesExtrinsic, "src/tests/vectors/codec/codec/data/disputes_extrinsic.json");
}

test "codec: decode guarantees_extrinsic" {
    try testDecodeAndCompare(types.GuaranteesExtrinsic, codec_test.types.GuaranteesExtrinsic, "src/tests/vectors/codec/codec/data/guarantees_extrinsic.json");
}

test "codec: decode preimages_extrinsic" {
    try testDecodeAndCompare(types.PreimagesExtrinsic, codec_test.types.PreimagesExtrinsic, "src/tests/vectors/codec/codec/data/preimages_extrinsic.json");
}

test "codec: decode refine_context" {
    try testDecodeAndCompare(types.RefineContext, codec_test.types.RefineContext, "src/tests/vectors/codec/codec/data/refine_context.json");
}

test "codec: decode tickets_extrinsic" {
    try testDecodeAndCompare(types.TicketsExtrinsic, codec_test.types.TicketsExtrinsic, "src/tests/vectors/codec/codec/data/tickets_extrinsic.json");
}

test "codec: decode work_item" {
    try testDecodeAndCompare(types.WorkItem, codec_test.types.WorkItem, "src/tests/vectors/codec/codec/data/work_item.json");
}

test "codec: decode work_package" {
    try testDecodeAndCompare(types.WorkPackage, codec_test.types.WorkPackage, "src/tests/vectors/codec/codec/data/work_package.json");
}

test "codec: decode work_report" {
    try testDecodeAndCompare(types.WorkReport, codec_test.types.WorkReport, "src/tests/vectors/codec/codec/data/work_report.json");
}

test "codec: decode work_result_0" {
    try testDecodeAndCompare(types.WorkResult, codec_test.types.WorkResult, "src/tests/vectors/codec/codec/data/work_result_0.json");
}

test "codec: decode work_result_1" {
    try testDecodeAndCompare(types.WorkResult, codec_test.types.WorkResult, "src/tests/vectors/codec/codec/data/work_result_1.json");
}
