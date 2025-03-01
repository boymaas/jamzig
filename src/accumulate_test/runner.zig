const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/accumulate.zig");
const accumulate = @import("../accumulate.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const state_delta = @import("../state_delta.zig");
const diff = @import("../tests/diff.zig");
const Params = @import("../jam_params.zig").Params;

pub fn processAccumulateReports(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    base_state: *state.JamState(params),
) !types.AccumulateRoot {
    // Create a StateTransition using the provided base_state
    var stx = try state_delta.StateTransition(params).init(
        allocator,
        base_state,
        params.Time().init(test_case.pre_state.slot, test_case.input.slot),
    );
    defer stx.deinit();

    // Transition time, with input slot
    try @import("../stf/time.zig").transition(params, &stx, test_case.input.slot);

    // Process the newly available reports
    const results = try accumulate.processAccumulateReports(
        params,
        &stx,
        test_case.input.reports,
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

    // Process the work reports using StateTransition
    const process_result = processAccumulateReports(
        params,
        allocator,
        &test_case,
        &pre_state,
    );

    // Print delta if availabe
    var delta = try diff.diffBasedOnFormat(allocator, &pre_state, &expected_state);
    defer delta.deinit(allocator);
    delta.debugPrint();

    // Check expected output
    switch (test_case.output) {
        .err => {
            if (process_result) |_| {
                std.debug.print("\nGot success, expected error\n", .{});
                return error.UnexpectedSuccess;
            } else |_| {
                // Error was expected, test passes
            }
        },
        .ok => |expected_root| {
            if (process_result) |actual_root| {
                if (!std.mem.eql(u8, &actual_root, &expected_root)) {
                    std.debug.print("Mismatch: actual root != expected root\n", .{});
                    return error.RootMismatch;
                }
            } else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }

    // If we have a diff return error
    if (delta.hasChanges()) {
        return error.StateDiffDetected;
    }
}
