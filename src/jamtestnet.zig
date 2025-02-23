const std = @import("std");
const testing = std.testing;

pub const parsers = @import("jamtestnet/parsers.zig");
pub const state_transitions = @import("jamtestnet/state_transitions.zig");

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_dict = @import("state_dictionary.zig");
const codec = @import("codec.zig");
const services = @import("services.zig");

const jam_params = @import("jam_params.zig");

const jamtestnet = @This();

const trace = @import("tracing.zig").scoped(.stf_test);

// we derive from the normal settings
// see: https://github.com/jam-duna/jamtestnet/blob/main/chainspecs.json#L2
pub const JAMDUNA_PARAMS = jam_params.Params{
    .epoch_length = 12,
    .ticket_submission_end_epoch_slot = 10,
    .validators_count = 6,
    .validators_super_majority = 5,
    .validator_rotation_period = 4,
    .core_count = 2,
    .avail_bitfield_bytes = (2 + 7) / 8,
    // JAMDUNA changes
    .max_ticket_entries_per_validator = 3, // N
    .max_authorizations_queue_items = 80, // Q
    .max_authorizations_pool_items = 8, // O
};

test "jamduna:fallback" {
    const allocator = std.testing.allocator;
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        allocator,
        "src/jamtestnet/teams/jamduna/data/fallback/state_transitions",
    );
}

test "jamduna:safrole" {
    const allocator = std.testing.allocator;
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        allocator,
        "src/jamtestnet/teams/jamduna/data/safrole/state_transitions",
    );
}

test "jamduna:assurances" {
    const allocator = std.testing.allocator;
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        allocator,
        "src/jamtestnet/teams/jamduna/data/assurances/state_transitions",
    );
}

test "jamzig:safrole" {
    const allocator = std.testing.allocator;
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        allocator,
        "src/jamtestnet/teams/jamzig/safrole/state_transitions",
    );
}

// NOTE: disabled, not following the standard.
test "javajam:safrole" {
    const allocator = std.testing.allocator;
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        allocator,
        "src/jamtestnet/teams/javajam/state_transitions",
    );
}

/// Run state transition tests using vectors from the specified directory
pub fn runStateTransitionTests(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    test_dir: []const u8,
) !void {
    std.debug.print("\nRunning state transition tests from: {s}\n", .{test_dir});

    var state_transition_vectors = try jamtestnet.state_transitions.collectStateTransitions(test_dir, allocator);
    defer state_transition_vectors.deinit(allocator);
    std.debug.print("Collected {d} state transition vectors\n", .{state_transition_vectors.items().len});

    var current_state: ?state.JamState(params) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    for (state_transition_vectors.items()) |state_transition_vector| {
        // std.debug.print("\nProcessing transition {d}/{d}\n", .{ i + 1, state_transition_vectors.items().len });

        var state_transition = try state_transition_vector.decodeBin(params, allocator);
        defer state_transition.deinit(allocator);

        // std.debug.print("{}", .{types.fmt.format(state_transition)});
        std.debug.print("{}", .{types.fmt.format(state_transition.block)});

        // First validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        // std.debug.print("Block header slot: {d}\n", .{state_transition.block.header.slot});

        // Initialize genesis state if needed
        if (current_state == null) {
            // std.debug.print("Initializing genesis state...\n", .{});
            var dict = try state_transition.preStateAsMerklizationDict(allocator);
            defer dict.deinit();
            current_state = try state_dict.reconstruct.reconstructState(
                params,
                allocator,
                &dict,
            );
            // std.debug.print("Genesis state initialized\n", .{});
        }

        // std.debug.print("Executing state transition...\n", .{});
        var transition = try stf.stateTransition(
            params,
            allocator,
            &current_state.?,
            &state_transition.block,
        );
        defer transition.deinitHeap();

        // Merge transition into base state
        try transition.mergePrimeOntoBase();

        // Log block information for debugging
        @import("sequoia.zig").logging.printBlockEntropyDebug(
            JAMDUNA_PARAMS,
            &state_transition.block,
            &current_state.?,
        );

        // Validate against expected state
        var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
        defer expected_state_mdict.deinit();

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        // Check for differences from expected state
        if (expected_state_diff.has_changes()) {
            std.debug.print("{}", .{expected_state_diff});

            var expected_state = try state_dict.reconstruct.reconstructState(params, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            std.debug.print("{}", .{expected_state});

            try @import("tests/diff.zig").printDiffBasedOnFormatToStdErr(allocator, &current_state.?, &expected_state);
            return error.UnexpectedStateDiff;
        }

        // Validate state root
        const state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.post_state.state_root,
            &state_root,
        );
    }
}
