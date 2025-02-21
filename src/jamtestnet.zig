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
const JAMDUNA_PARAMS = jam_params.Params{
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
    .max_authorizations_pool_items = 2,
};

test "jamduna:fallback" {
    const allocator = std.testing.allocator;
    std.debug.print("\nJAMDUNA Fallback\n", .{});

    var state_transition_vectors = try jamtestnet.state_transitions.collectStateTransitions("src/jamtestnet/teams/jamduna/data/fallback", allocator);
    defer state_transition_vectors.deinit(allocator);
    std.debug.print("Collected {d} state transition vectors\n", .{state_transition_vectors.items().len});

    var current_state: ?state.JamState(JAMDUNA_PARAMS) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    for (state_transition_vectors.items(), 0..) |state_transition_vector, i| {
        std.debug.print("\nProcessing transition {d}/{d}\n", .{ i + 1, state_transition_vectors.items().len });

        var state_transition = try state_transition_vector.decodeBin(JAMDUNA_PARAMS, allocator);
        defer state_transition.deinit(allocator);

        // First lest validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        std.debug.print("Block header slot: {d}\n", .{state_transition.block.header.slot});

        if (current_state == null) {
            std.debug.print("Initializing genesis state...\n", .{});
            var dict = try state_transition.preStateAsMerklizationDict(allocator);
            defer dict.deinit();
            current_state = try state_dict.reconstruct.reconstructState(
                JAMDUNA_PARAMS,
                allocator,
                &dict,
            );
            std.debug.print("Genesis state initialized\n", .{});
        }

        // std.debug.print("Current state {s}", .{current_state.?});

        std.debug.print("Executing state transition...\n", .{});
        var transition = try stf.stateTransition(
            JAMDUNA_PARAMS,
            allocator,
            &current_state.?,
            &state_transition.block,
        );
        defer transition.deinitHeap();

        // Let's assume the transition went well, lets merge into
        // the base state.
        try transition.mergePrimeOntoBase();

        // std.debug.print("New state {s}", .{types.fmt.format(current_state.?)});

        // Now lets produce a MerkleDict for our current state and from the expected state
        // They should result in the same output.
        var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
        defer expected_state_mdict.deinit();

        // std.debug.print("{}\n", .{types.fmt.format(&expected_state_mdict)});

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        // Check if we have difference from the expected state
        if (expected_state_diff.has_changes()) {
            // std.debug.print("State MDICT Diff: {}", .{expected_state_diff});

            var expected_state = try state_dict.reconstruct.reconstructState(JAMDUNA_PARAMS, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            try @import("tests/diff.zig").printDiffBasedOnFormatToStdErr(allocator, &current_state.?, &expected_state);
            return error.UnexpectedStateDiff;
        }

        // Ensure our state root matches the expected state
        const state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.post_state.state_root,
            &state_root,
        );
    }
}

test "jamduna:safrole" {
    const allocator = std.testing.allocator;
    std.debug.print("\nJAMDUNA Safrole\n", .{});

    var state_transition_vectors = try jamtestnet.state_transitions.collectStateTransitions("src/jamtestnet/teams/jamduna/data/safrole", allocator);
    defer state_transition_vectors.deinit(allocator);
    std.debug.print("Collected {d} state transition vectors\n", .{state_transition_vectors.items().len});

    var current_state: ?state.JamState(JAMDUNA_PARAMS) = null;
    defer {
        if (current_state) |*cs| cs.deinit(allocator);
    }

    for (state_transition_vectors.items(), 0..) |state_transition_vector, i| {
        std.debug.print("\nProcessing transition {d}/{d}\n", .{ i + 1, state_transition_vectors.items().len });

        var state_transition = try state_transition_vector.decodeBin(JAMDUNA_PARAMS, allocator);
        defer state_transition.deinit(allocator);

        // First lest validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // Validator Root Calculations
        try state_transition.validateRoots(allocator);

        std.debug.print("Block header slot: {d}\n", .{state_transition.block.header.slot});

        if (current_state == null) {
            std.debug.print("Initializing genesis state...\n", .{});
            var dict = try state_transition.preStateAsMerklizationDict(allocator);
            defer dict.deinit();
            current_state = try state_dict.reconstruct.reconstructState(
                JAMDUNA_PARAMS,
                allocator,
                &dict,
            );
            std.debug.print("Genesis state initialized\n", .{});
        }

        // std.debug.print("Current state {s}", .{current_state.?});

        std.debug.print("Executing state transition...\n", .{});
        var transition = try stf.stateTransition(
            JAMDUNA_PARAMS,
            allocator,
            &current_state.?,
            &state_transition.block,
        );
        defer transition.deinitHeap();

        // Let's assume the transition went well, lets merge into
        // the base state.
        try transition.mergePrimeOntoBase();

        // std.debug.print("New state {s}", .{types.fmt.format(current_state.?)});

        // Now lets produce a MerkleDict for our current state and from the expected state
        // They should result in the same output.
        var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.postStateAsMerklizationDict(allocator);
        defer expected_state_mdict.deinit();

        // std.debug.print("{}\n", .{types.fmt.format(&expected_state_mdict)});

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        // Check if we have difference from the expected state
        if (expected_state_diff.has_changes()) {
            // std.debug.print("State MDICT Diff: {}", .{expected_state_diff});

            var expected_state = try state_dict.reconstruct.reconstructState(JAMDUNA_PARAMS, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            try @import("tests/diff.zig").printDiffBasedOnFormatToStdErr(allocator, &current_state.?, &expected_state);
            return error.UnexpectedStateDiff;
        }

        // Ensure our state root matches the expected state
        const state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.post_state.state_root,
            &state_root,
        );
    }
}
