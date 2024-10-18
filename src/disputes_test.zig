const std = @import("std");
const tvector = @import("tests/vectors/libs/disputes.zig");

const diffz = @import("disputes_test/diffz.zig");
const converters = @import("disputes_test/converters.zig");

const disputes = @import("disputes.zig");

const stf = @import("stf.zig");

const runDisputeTest = @import("disputes_test/runner.zig").runDisputeTest;

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

test "tiny/progress_with_no_verdicts-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_no_verdicts-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_bad_signatures-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_bad_signatures-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );
    //

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_bad_signatures-2.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_bad_signatures-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-2.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-3.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-3.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );
    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-4.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-4.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-5.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-5.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );
    //

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-6.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-6.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_culprits-7.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-7.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-2.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-3.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-3.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-4.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-4.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-5.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-5.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-6.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-6.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_faults-7.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-7.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdict_signatures_from_previous_set-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdict_signatures_from_previous_set-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdict_signatures_from_previous_set-2.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdict_signatures_from_previous_set-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdicts-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdicts-2.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdicts-3.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-3.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdicts-4.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-4.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdicts-5.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-5.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

test "tiny/progress_with_verdicts-6.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-6.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

// This test is the only one which will change the rho, the rest is Phi.only
test "tiny/progress_invalidates_avail_assignments-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_invalidates_avail_assignments-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );
    //

    try runDisputeTest(allocator, TINY_PARAMS, test_vector.value);
}

//  _____      _ ___     __        _
// |  ___|   _| | \ \   / /__  ___| |_ ___  _ __ ___
// | |_ | | | | | |\ \ / / _ \/ __| __/ _ \| '__/ __|
// |  _|| |_| | | | \ V /  __/ (__| || (_) | |  \__ \
// |_|   \__,_|_|_|  \_/ \___|\___|\__\___/|_|  |___/

pub const FULL_PARAMS = @import("jam_params.zig").FULL_PARAMS;

// Now run all the full vectors
fn runFullTest(allocator: std.mem.Allocator, test_json: []const u8) !void {
    std.debug.print("Running full test: {s}\n", .{test_json});
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try runDisputeTest(allocator, FULL_PARAMS, test_vector.value);
}

test "XXX" {
    const allocator = std.testing.allocator;

    const full_test_files = [_][]const u8{
        "src/tests/vectors/disputes/disputes/full/progress_invalidates_avail_assignments-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_bad_signatures-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_bad_signatures-2.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-2.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-3.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-4.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-5.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-6.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_culprits-7.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-2.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-3.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-4.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-5.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-6.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_faults-7.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_no_verdicts-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdict_signatures_from_previous_set-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdict_signatures_from_previous_set-2.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdicts-1.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdicts-2.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdicts-3.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdicts-4.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdicts-5.json",
        "src/tests/vectors/disputes/disputes/full/progress_with_verdicts-6.json",
    };

    for (full_test_files) |test_file| {
        try runFullTest(allocator, test_file);
    }
}
