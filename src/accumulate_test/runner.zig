const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/accumulate.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const state_delta = @import("../state_delta.zig");
const diff = @import("../tests/diff.zig");
const state_diff = @import("../tests/state_diff.zig");
const Params = @import("../jam_params.zig").Params;

pub fn processAccumulateReports(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    base_state: *state.JamState(params),
) !@import("../accumulate/execution.zig").ProcessAccumulationResult {
    // Create a StateTransition using the provided base_state
    var stx = try state_delta.StateTransition(params).init(
        allocator,
        base_state,
        params.Time().init(test_case.pre_state.slot, test_case.input.slot),
    );
    defer stx.deinit();

    // Transition time, with input slot
    try @import("../stf/time.zig").transition(params, &stx, test_case.input.slot);

    // Process the newly available reports using STF function
    var results = try @import("../stf/accumulate.zig").transition(
        params,
        allocator,
        &stx,
        test_case.input.reports,
    );
    errdefer results.deinit(allocator);

    // Call validator stats transition to update Pi with accumulation statistics
    const validator_stats_input = @import("../stf/validator_stats.zig").ValidatorStatsInput.Empty;

    try @import("../stf/validator_stats.zig").transition(
        params,
        &stx,
        validator_stats_input,
        &[_]types.WorkReport{}, // empty ready reports, these stats are not in the test vector
        &results.accumulation_stats,
        &results.transfer_stats,
    );

    // Merge prime into base
    try stx.mergePrimeOntoBase();

    return results;
}

pub fn runAccumulateTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    // Convert pre-state and post-state from test vector format to native format
    var pre_state = try converters.convertTestStateIntoJamState(params, allocator, test_case.pre_state);
    defer pre_state.deinit(allocator);

    // Convert post-state for later comparison
    var expected_state = try converters.convertTestStateIntoJamState(params, allocator, test_case.post_state);
    defer expected_state.deinit(allocator);

    // std.debug.print("State: {s}\n", .{expected_state});

    // Process the work reports using StateTransition
    const process_result = processAccumulateReports(
        params,
        allocator,
        &test_case,
        &pre_state,
    );

    // Check expected output first
    switch (test_case.output) {
        .err => {
            if (process_result) |result| {
                var mutable_result = result;
                mutable_result.deinit(allocator);
                std.debug.print("\nGot success, expected error\n", .{});
                return error.UnexpectedSuccess;
            } else |_| {
                // Error was expected, test passes
            }
        },
        .ok => |expected_root| {
            if (process_result) |result| {
                var mutable_result = result;
                defer mutable_result.deinit(allocator);

                if (!std.mem.eql(u8, &result.accumulate_root, &expected_root)) {
                    std.debug.print("Mismatch: actual root != expected root\n", .{});
                    return error.RootMismatch;
                }

                // Print delta if available
                var delta = try state_diff.JamStateDiff(params).build(allocator, &pre_state, &expected_state);
                defer delta.deinit();
                delta.printToStdErr();

                // If we have a diff return error
                if (delta.hasChanges()) {
                    return error.StateDiffDetected;
                }
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }
}
