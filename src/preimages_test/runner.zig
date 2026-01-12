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
    var stx = try state_delta.StateTransition(params).init(
        allocator,
        base_state,
        params.Time().init(test_case.input.slot - 1, test_case.input.slot),
    );
    defer stx.deinit();

    try preimages.processPreimagesExtrinsic(
        params,
        &stx,
        test_case.input.preimages,
    );

    try stx.mergePrimeOntoBase();
}

pub fn runPreimagesTest(comptime params: Params, allocator: std.mem.Allocator, test_case: tvector.TestCase) !void {
    var pre_state = try converters.convertTestStateIntoJamState(
        params,
        allocator,
        test_case.pre_state,
        test_case.input.slot,
    );
    defer pre_state.deinit(allocator);

    var expected_state = try converters.convertTestStateIntoJamState(
        params,
        allocator,
        test_case.post_state,
        test_case.input.slot,
    );
    defer expected_state.deinit(allocator);

    const process_result = processPreimagesExtrinsic(
        params,
        allocator,
        &test_case,
        &pre_state,
    );

    var delta = try state_diff.JamStateDiff(params).build(allocator, &pre_state, &expected_state);
    defer delta.deinit();
    delta.printToStdErr();

    switch (test_case.output) {
        .err => {
            if (process_result) {
                std.debug.print("\nGot success, expected error\n", .{});
                return error.UnexpectedSuccess;
            } else |_| {}
        },
        .ok => {
            if (process_result) |_| {} else |err| {
                std.debug.print("UnexpectedError: {any}\n", .{err});
                return error.UnexpectedError;
            }
        },
    }

    if (delta.hasChanges()) {
        return error.StateDiffDetected;
    }
}
