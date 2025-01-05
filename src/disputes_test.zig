const std = @import("std");
const tvector = @import("jamtestvectors/disputes.zig");

const diffz = @import("disputes_test/diffz.zig");
const converters = @import("disputes_test/converters.zig");

const disputes = @import("disputes.zig");

const stf = @import("stf.zig");

const BASE_PATH = "src/jamtestvectors/data/disputes/";

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
    const test_bin = BASE_PATH ++ "tiny/progress_with_no_verdicts-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_bad_signatures-1.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_bad_signatures-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );
    //

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_bad_signatures-2.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_bad_signatures-2.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-1.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-2.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-2.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-3.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-3.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );
    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-4.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-4.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-5.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-5.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );
    //

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-6.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-6.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_culprits-7.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_culprits-7.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-1.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-2.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-2.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-3.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-3.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-4.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-4.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-5.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-5.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-6.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-6.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_faults-7.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_faults-7.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdict_signatures_from_previous_set-1.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdict_signatures_from_previous_set-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdict_signatures_from_previous_set-2.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdict_signatures_from_previous_set-2.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdicts-1.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdicts-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdicts-2.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdicts-2.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdicts-3.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdicts-3.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdicts-4.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdicts-4.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdicts-5.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdicts-5.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

test "tiny/progress_with_verdicts-6.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_with_verdicts-6.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

// This test is the only one which will change the rho, the rest is Phi.only
test "tiny/progress_invalidates_avail_assignments-1.json" {
    const allocator = std.testing.allocator;
    const test_bin = BASE_PATH ++ "tiny/progress_invalidates_avail_assignments-1.bin";
    var test_vector = try tvector.TestCase.build_from(TINY_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    // try printStateDiff(
    //     allocator,
    //     &test_vector.pre_state,
    //     &test_vector.post_state,
    // );
    //

    try runDisputeTest(allocator, TINY_PARAMS, test_vector);
}

//  _____      _ ___     __        _
// |  ___|   _| | \ \   / /__  ___| |_ ___  _ __ ___
// | |_ | | | | | |\ \ / / _ \/ __| __/ _ \| '__/ __|
// |  _|| |_| | | | \ V /  __/ (__| || (_) | |  \__ \
// |_|   \__,_|_|_|  \_/ \___|\___|\__\___/|_|  |___/

pub const FULL_PARAMS = @import("jam_params.zig").FULL_PARAMS;

// Now run all the full vectors
fn runFullTest(allocator: std.mem.Allocator, test_bin: []const u8) !void {
    std.debug.print("Running full test: {s}\n", .{test_bin});
    var test_vector = try tvector.TestCase.build_from(FULL_PARAMS, allocator, test_bin);
    defer test_vector.deinit(allocator);

    try runDisputeTest(allocator, FULL_PARAMS, test_vector);
}

test "XXX" {
    const allocator = std.testing.allocator;

    const full_test_files = [_][]const u8{
        BASE_PATH ++ "full/progress_invalidates_avail_assignments-1.bin",
        BASE_PATH ++ "full/progress_with_bad_signatures-1.bin",
        BASE_PATH ++ "full/progress_with_bad_signatures-2.bin",
        BASE_PATH ++ "full/progress_with_culprits-1.bin",
        BASE_PATH ++ "full/progress_with_culprits-2.bin",
        BASE_PATH ++ "full/progress_with_culprits-3.bin",
        BASE_PATH ++ "full/progress_with_culprits-4.bin",
        BASE_PATH ++ "full/progress_with_culprits-5.bin",
        BASE_PATH ++ "full/progress_with_culprits-6.bin",
        BASE_PATH ++ "full/progress_with_culprits-7.bin",
        BASE_PATH ++ "full/progress_with_faults-1.bin",
        BASE_PATH ++ "full/progress_with_faults-2.bin",
        BASE_PATH ++ "full/progress_with_faults-3.bin",
        BASE_PATH ++ "full/progress_with_faults-4.bin",
        BASE_PATH ++ "full/progress_with_faults-5.bin",
        BASE_PATH ++ "full/progress_with_faults-6.bin",
        BASE_PATH ++ "full/progress_with_faults-7.bin",
        BASE_PATH ++ "full/progress_with_no_verdicts-1.bin",
        BASE_PATH ++ "full/progress_with_verdict_signatures_from_previous_set-1.bin",
        BASE_PATH ++ "full/progress_with_verdict_signatures_from_previous_set-2.bin",
        BASE_PATH ++ "full/progress_with_verdicts-1.bin",
        BASE_PATH ++ "full/progress_with_verdicts-2.bin",
        BASE_PATH ++ "full/progress_with_verdicts-3.bin",
        BASE_PATH ++ "full/progress_with_verdicts-4.bin",
        BASE_PATH ++ "full/progress_with_verdicts-5.bin",
        BASE_PATH ++ "full/progress_with_verdicts-6.bin",
    };

    for (full_test_files) |test_file| {
        try runFullTest(allocator, test_file);
    }
}
