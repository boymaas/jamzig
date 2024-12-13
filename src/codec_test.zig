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

const test_cases = [_]TestCase{
    .{ .name = "header_0", .domain_type = "Header" },
    .{ .name = "header_1", .domain_type = "Header" },
    .{ .name = "extrinsic", .domain_type = "Extrinsic" },
    .{ .name = "block", .domain_type = "Block" },
    .{ .name = "assurances_extrinsic", .domain_type = "AssurancesExtrinsic" },
    .{ .name = "disputes_extrinsic", .domain_type = "DisputesExtrinsic" },
    .{ .name = "guarantees_extrinsic", .domain_type = "GuaranteesExtrinsic" },
    .{ .name = "preimages_extrinsic", .domain_type = "PreimagesExtrinsic" },
    .{ .name = "refine_context", .domain_type = "RefineContext" },
    .{ .name = "tickets_extrinsic", .domain_type = "TicketsExtrinsic" },
    .{ .name = "work_item", .domain_type = "WorkItem" },
    .{ .name = "work_package", .domain_type = "WorkPackage" },
    .{ .name = "work_report", .domain_type = "WorkReport" },
    .{ .name = "work_result_0", .domain_type = "WorkResult" },
    .{ .name = "work_result_1", .domain_type = "WorkResult" },
};

test "codec: decode" {
    inline for (test_cases) |test_case| {
        const test_name = "codec: decode " ++ test_case.name;
        std.debug.print("{s}\n", .{test_name});

        try testDecodeAndCompare(test_case);
    }
}

/// Helper function to decode and compare test vectors
fn testDecodeAndCompare(comptime test_case: TestCase) !void {
    const allocator = std.testing.allocator;

    const json_path = try std.fmt.allocPrint(allocator, "src/jamtestvectors/data/codec/data/{s}.json", .{test_case.name});
    defer allocator.free(json_path);
    const bin_path = try std.fmt.allocPrint(allocator, "src/jamtestvectors/data/codec/data/{s}.bin", .{test_case.name});
    defer allocator.free(bin_path);

    const DomainType = @field(types, test_case.domain_type);
    const VectorType = @field(codec_test.json_types, test_case.domain_type);

    // Load the binary test vector data
    var decoded = try loader.loadAndDeserializeTestVector(DomainType, TINY_PARAMS, allocator, bin_path);
    defer decoded.deinit(allocator);

    // Load the json expeceted vector data
    const vector = try codec_test.CodecTestVector(VectorType).build_from(allocator, json_path);
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
