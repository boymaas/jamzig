const std = @import("std");
const testing = std.testing;

const codec = @import("codec.zig");
const codec_test = @import("jamtestvectors/codec.zig");

const convert = @import("jamtestvectors/json_convert/codec.zig");

const types = @import("types.zig");
const jam_params = @import("jam_params.zig");

const loader = @import("jamtestvectors/loader.zig");

/// The Tiny PARAMS as they are defined in the ASN
const TINY_PARAMS = jam_params.TINY_PARAMS;

const TestCase = struct {
    name: []const u8,
    domain_type: []const u8,
};

test "codec: decode header_0" {
    try testDecodeAndCompare(.{ .name = "header_0", .domain_type = "Header" });
}

test "codec: decode header_1" {
    try testDecodeAndCompare(.{ .name = "header_1", .domain_type = "Header" });
}

test "codec: decode extrinsic" {
    try testDecodeAndCompare(.{ .name = "extrinsic", .domain_type = "Extrinsic" });
}

test "codec: decode block" {
    try testDecodeAndCompare(.{ .name = "block", .domain_type = "Block" });
}

test "codec: decode assurances_extrinsic" {
    try testDecodeAndCompare(.{ .name = "assurances_extrinsic", .domain_type = "AssurancesExtrinsic" });
}

test "codec: decode disputes_extrinsic" {
    try testDecodeAndCompare(.{ .name = "disputes_extrinsic", .domain_type = "DisputesExtrinsic" });
}

test "codec: decode guarantees_extrinsic" {
    try testDecodeAndCompare(.{ .name = "guarantees_extrinsic", .domain_type = "GuaranteesExtrinsic" });
}

test "codec: decode preimages_extrinsic" {
    try testDecodeAndCompare(.{ .name = "preimages_extrinsic", .domain_type = "PreimagesExtrinsic" });
}

test "codec: decode refine_context" {
    try testDecodeAndCompare(.{ .name = "refine_context", .domain_type = "RefineContext" });
}

test "codec: decode tickets_extrinsic" {
    try testDecodeAndCompare(.{ .name = "tickets_extrinsic", .domain_type = "TicketsExtrinsic" });
}

test "codec: decode work_item" {
    try testDecodeAndCompare(.{ .name = "work_item", .domain_type = "WorkItem" });
}

// TODO: Fix work_package codec test - field order/encoding issue
test "codec: decode work_package" {
    try testDecodeAndCompare(.{ .name = "work_package", .domain_type = "WorkPackage" });
}

test "codec: decode work_report" {
    try testDecodeAndCompare(.{ .name = "work_report", .domain_type = "WorkReport" });
}

test "codec: decode work_result_0" {
    try testDecodeAndCompare(.{ .name = "work_result_0", .domain_type = "WorkResult" });
}

test "codec: decode work_result_1" {
    try testDecodeAndCompare(.{ .name = "work_result_1", .domain_type = "WorkResult" });
}

/// Helper function to decode and compare test vectors
fn testDecodeAndCompare(comptime test_case: TestCase) !void {
    const allocator = std.testing.allocator;

    const json_path = try std.fmt.allocPrint(allocator, "src/jamtestvectors/data/codec/tiny/{s}.json", .{test_case.name});
    defer allocator.free(json_path);
    const bin_path = try std.fmt.allocPrint(allocator, "src/jamtestvectors/data/codec/tiny/{s}.bin", .{test_case.name});
    defer allocator.free(bin_path);

    const DomainType = @field(types, test_case.domain_type);
    const VectorType = @field(codec_test.json_types, test_case.domain_type);

    // Load the binary test vector data
    var decoded = try loader.loadAndDeserializeTestVector(DomainType, TINY_PARAMS, allocator, bin_path);
    defer decoded.deinit(allocator);

    // const format = @import("types/fmt.zig").format;
    // std.debug.print("decoded:\n{s}\n", .{format(decoded)});

    // Load the json expeceted vector data
    var vector = try codec_test.CodecTestVector(VectorType).build_from(allocator, json_path);
    defer vector.deinit();

    // Convert the json into domain objects
    const expected: DomainType = try convert.convert(VectorType, DomainType, allocator, vector.expected.value);
    defer convert.generic.free(allocator, expected);

    // TODO: how exactly are the complex types compared? Trace into this
    try std.testing.expectEqualDeep(expected, decoded);

    // Serialize the decoded value
    const serialized = try codec.serializeAlloc(DomainType, TINY_PARAMS, allocator, decoded);
    defer allocator.free(serialized);

    // Compare the serialized result with the original binary data
    try std.testing.expectEqualSlices(u8, vector.binary, serialized);
}
