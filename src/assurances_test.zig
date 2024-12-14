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

pub const TINY_PARAMS = @import("jam_params.zig").TINY_PARAMS;

// assurance_for_not_engaged_core-1.bin
// assurances_for_stale_report-1.bin
// assurances_with_bad_signature-1.bin
// assurances_with_bad_validator_index-1.bin
// assurance_with_bad_attestation_parent-1.bin
// assurers_not_sorted_or_unique-1.bin
// assurers_not_sorted_or_unique-2.bin
// no_assurances-1.bin
// no_assurances_with_stale_report-1.bin
// some_assurances-1.bin

const loader = @import("jamtestvectors/loader.zig");

test "tiny/no_assurances-1.bin" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/no_assurances-1.bin";

    const test_vector = try loader.loadAndDeserializeTestVector(
        tvector.TestCase,
        TINY_PARAMS,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    try runAssuranceTest(allocator, TINY_PARAMS, test_vector);
}

// Full test vectors
pub const FULL_PARAMS = @import("jam_params.zig").FULL_PARAMS;

fn runFullTest(allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("Running full test: {s}\n", .{test_bin});

    const test_vector = try loader.loadAndDeserializeTestVector(
        tvector.TestCase,
        FULL_PARAMS,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    try runAssuranceTest(allocator, FULL_PARAMS, test_vector);
}

test "Full test vectors" {
    const allocator = std.testing.allocator;

    const full_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "full");

    for (full_test_files.items()) |test_file| {
        if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
            continue;
        }
        try runFullTest(allocator, test_file.path);
    }
}
