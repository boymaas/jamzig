const std = @import("std");
const tvector = @import("tests/vectors/libs/disputes.zig");

const diffz = @import("disputes_test/diffz.zig");

const allocator = std.testing.allocator;

fn printStateDiff(alloc: std.mem.Allocator, pre_state: *const tvector.State, post_state: *const tvector.State) !void {
    const state_diff = try diffz.diffStates(alloc, pre_state, post_state);
    defer allocator.free(state_diff);
    std.debug.print("\nState Diff: {s}\n", .{state_diff});
}

test "tiny/progress_with_no_verdicts-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_no_verdicts-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

// This test is the only one which will change the rho, the rest is Phi.only
test "tiny/progress_invalidates_avail_assignments-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_invalidates_avail_assignments-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_bad_signatures-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_bad_signatures-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_bad_signatures-2.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_bad_signatures-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-2.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-3.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-3.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-4.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-4.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-5.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-5.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-6.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-6.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_culprits-7.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_culprits-7.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-2.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-3.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-3.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-4.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-4.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-5.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-5.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-6.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-6.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_faults-7.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_faults-7.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdict_signatures_from_previous_set-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdict_signatures_from_previous_set-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdict_signatures_from_previous_set-2.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdict_signatures_from_previous_set-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdicts-1.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-1.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdicts-2.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-2.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdicts-3.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-3.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdicts-4.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-4.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdicts-5.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-5.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}

test "tiny/progress_with_verdicts-6.json" {
    const test_json = "src/tests/vectors/disputes/disputes/tiny/progress_with_verdicts-6.json";
    const test_vector = try tvector.TestVector.build_from(allocator, test_json);
    defer test_vector.deinit();

    try printStateDiff(
        allocator,
        &test_vector.value.pre_state,
        &test_vector.value.post_state,
    );
}
