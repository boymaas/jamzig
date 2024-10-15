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

pub const TINY_PARAMS = @import("jam_params.zig").Params{
    .epoch_length = 12,
    // TODO: what value of Y (ticket_submission_end_slot) should we use for the tiny vectors, now set to
    // same ratio. Production values is 500 of and epohc length of 600 which
    // would suggest 10
    .ticket_submission_end_epoch_slot = 10,
    .max_ticket_entries_per_validator = 2,
    .validators_count = 6,
};

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
}

// This test is the only one which will change the rho, the rest is Phi.only
test "tiny/progress_invalidates_avail_assignments-1.json" {
    const allocator = std.testing.allocator;
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_invalidates_avail_assignments-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    return error.NotImplementedYet;

    // try printStateDiff(
    //     allocator,
    //     &test_vector.value.pre_state,
    //     &test_vector.value.post_state,
    // );
}
