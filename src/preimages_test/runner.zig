const std = @import("std");
const converters = @import("./converters.zig");
const tvector = @import("../jamtestvectors/preimages.zig");
const preimages = @import("../preimages.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const helpers = @import("../tests/helpers.zig");
const state_delta = @import("../state_delta.zig");
const diff = @import("../tests/diff.zig");
const state_diff = @import("../tests/state_diff.zig");
const Params = @import("../jam_params.zig").Params;

pub fn processPreimagesExtrinsic(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_case: *const tvector.TestCase,
    base_state: *state.JamState(params),
) !void {
    // Create a StateTransition using the provided base_state
    var stx = try state_delta.StateTransition(params).init(
        allocator,
        base_state,
        params.Time().init(test_case.input.slot - 1, test_case.input.slot),
    );
    defer stx.deinit();

    // Process the preimages extrinsic
    try preimages.processPreimagesExtrinsic(
        params,
        &stx,
        test_case.input.preimages,
    );

    // Merge prime into base
    try stx.mergePrimeOntoBase();
}

pub fn runPreimagesTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    // Convert pre-state and post-state from test vector format to native format
    var pre_state = try converters.convertTestStateIntoJamState(
        params,
        allocator,
        test_case.pre_state,
        test_case.input.slot,
    );
    defer pre_state.deinit(allocator);

    // Convert post-state for later comparison
    var expected_state = try converters.convertTestStateIntoJamState(
        params,
        allocator,
        test_case.post_state,
        test_case.input.slot,
    );
    defer expected_state.deinit(allocator);

    // Process the preimages extrinsic using StateTransition
    const process_result = processPreimagesExtrinsic(
        params,
        allocator,
        &test_case,
        &pre_state,
    );

    // Print delta if available
    var delta = try state_diff.JamStateDiff(params).build(allocator, &pre_state, &expected_state);
    defer delta.deinit();
    delta.printToStdErr();

    // Check expected output
    switch (test_case.output) {
        .err => {
            if (process_result) {
                std.debug.print("\nGot success, expected error\n", .{});
                return error.UnexpectedSuccess;
            } else |_| {
                // Error was expected, test passes
            }
        },
        .ok => {
            if (process_result) |_| {
                // Success was expected, this is good
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
