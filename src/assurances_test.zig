const std = @import("std");

const tvector = @import("jamtestvectors/assurances.zig");
const runAssuranceTest = @import("assurances_test/runner.zig").runAssuranceTest;

const diffz = @import("disputes_test/diffz.zig");

const BASE_PATH = "src/jamtestvectors/data/stf/assurances/";

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
pub const FULL_PARAMS = jam_params.FULL_PARAMS;

const loader = @import("jamtestvectors/loader.zig");

fn runTest(comptime params: jam_params.Params, allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("Running test: {s}\n", .{test_bin});

    var test_vector = try loader.loadAndDeserializeTestVector(
        tvector.TestCase,
        params,
        allocator,
        test_bin,
    );
    defer test_vector.deinit(allocator);

    try runAssuranceTest(params, allocator, test_vector);
}

test "all.tiny.vectors" {
    const allocator = std.testing.allocator;

    var tiny_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "tiny");
    defer tiny_test_files.deinit();

    for (tiny_test_files.items()) |test_file| {
        if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
            continue;
        }
        try runTest(TINY_PARAMS, allocator, test_file.path);
    }
}

test "all.full.vectors" {
    const allocator = std.testing.allocator;

    var full_test_files = try @import("tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH ++ "full");
    defer full_test_files.deinit();

    for (full_test_files.items()) |test_file| {
        if (!std.mem.endsWith(u8, test_file.path, ".bin")) {
            continue;
        }
        try runTest(FULL_PARAMS, allocator, test_file.path);
    }
}
