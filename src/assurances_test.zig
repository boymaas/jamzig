const std = @import("std");

const tvector = @import("jamtestvectors/assurances.zig");
const runAssuranceTest = @import("assurances_test/runner.zig").runAssuranceTest;

const diffz = @import("disputes_test/diffz.zig");

const BASE_PATH = "src/jamtestvectors/data/assurances/";

// Debug helper function
fn printStateDiff(allocator: std.mem.Allocator, pre_state: *const tvector.State, post_state: *const tvector.State) !void {
    const state_diff = try diffz.diffStates(allocator, pre_state, post_state);
    defer allocator.free(state_diff);
    std.debug.print("\nState Diff: {s}\n", .{state_diff});
}

//  _____ _           __     __        _
// |_   _(_)_ __  _   \ \   / /__  ___| |_ ___  _ __ ___
//   | | | | '_ \| | | \ \ / / _ \/ __| __/ _ \| '__/ __|
//   | | | | | | | |_| |\ V /  __/ (__| || (_) | |  \__ \
//   |_| |_|_| |_|\__, | \_/ \___|\___|\__\___/|_|  |___/
//                |___/

pub const jam_params = @import("jam_params.zig");

// Tiny test vectors
pub const TINY_PARAMS = jam_params.TINY_PARAMS;

const TEST_FILES = [_][]const u8{
    "assurance_for_not_engaged_core-1.bin",
    "assurances_for_stale_report-1.bin",
    "assurances_with_bad_signature-1.bin",
    "assurances_with_bad_validator_index-1.bin",
    "assurance_with_bad_attestation_parent-1.bin",
    "assurers_not_sorted_or_unique-1.bin",
    "assurers_not_sorted_or_unique-2.bin",
    "no_assurances-1.bin",
    "no_assurances_with_stale_report-1.bin",
    "some_assurances-1.bin",
};

const loader = @import("jamtestvectors/loader.zig");

test "tiny/no_assurances-1.bin" {
    const allocator = std.testing.allocator;

    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/no_assurances-1.bin");
}

test "tiny/no_assurances_with_stale_report-1.bin" {
    const allocator = std.testing.allocator;
    try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/no_assurances_with_stale_report-1.bin");
}

// test "tiny/some_assurances-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/some_assurances-1.bin");
// }

// test "tiny/assurance_for_not_engaged_core-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurance_for_not_engaged_core-1.bin");
// }
//
// test "tiny/assurances_for_stale_report-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurances_for_stale_report-1.bin");
// }
//
// test "tiny/assurances_with_bad_signature-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurances_with_bad_signature-1.bin");
// }
//
// test "tiny/assurances_with_bad_validator_index-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurances_with_bad_validator_index-1.bin");
// }
//
// test "tiny/assurance_with_bad_attestation_parent-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurance_with_bad_attestation_parent-1.bin");
// }
//
// test "tiny/assurers_not_sorted_or_unique-1.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurers_not_sorted_or_unique-1.bin");
// }
//
// test "tiny/assurers_not_sorted_or_unique-2.bin" {
//     const allocator = std.testing.allocator;
//     try runTest(TINY_PARAMS, allocator, BASE_PATH ++ "tiny/assurers_not_sorted_or_unique-2.bin");
// }

// Full test vectors
pub const FULL_PARAMS = jam_params.FULL_PARAMS;

fn runTest(comptime params: jam_params.Params, allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("Running full test: {s}\n", .{test_bin});

    const test_vector = try loader.loadAndDeserializeTestVector(
        tvector.TestCase,
        params,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    try runAssuranceTest(FULL_PARAMS, allocator, test_vector);
}

test "all.tiny.vectors" {
    const allocator = std.testing.allocator;

    const full_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "tiny");

    for (full_test_files.items()) |test_file| {
        if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
            continue;
        }
        try runTest(FULL_PARAMS, allocator, test_file.path);
    }
}

test "all.full.vectors" {
    const allocator = std.testing.allocator;

    const full_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "full");

    for (full_test_files.items()) |test_file| {
        if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
            continue;
        }
        try runTest(FULL_PARAMS, allocator, test_file.path);
    }
}
