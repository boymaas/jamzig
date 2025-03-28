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

const jamtestnet = @import("jamtestnet/parsers.zig");

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
    .max_tickets_per_extrinsic = 3, // K
    .max_ticket_entries_per_validator = 3, // N
    .max_authorizations_queue_items = 80, // Q
    .max_authorizations_pool_items = 8, // O
    .preimage_expungement_period = 6, // D
};
// TODO: add these
// {
//     "tiny": {
//         "segment_size": 4104,
//         "ec_piece_size": 4,
//         "num_ec_pieces_per_segment": 1026,
//     },
//
test "jamduna:fallback" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestnet/teams/jamduna/data/fallback/state_transitions",
    );
}

test "jamduna:safrole" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestnet/teams/jamduna/data/safrole/state_transitions",
    );
}

test "jamduna:assurances" {
    const allocator = std.testing.allocator;

    const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestnet/teams/jamduna/data/assurances/state_transitions",
    );
}

test "jamduna:orderedaccumulation" {
    const allocator = std.testing.allocator;

    const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestnet/teams/jamduna/data/orderedaccumulation/state_transitions",
    );
}

test "javajam:safrole" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.jamduna.Loader(JAMDUNA_PARAMS){};
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestnet/teams/javajam/state_transitions",
    );
}

test "jamzig:safrole" {
    const allocator = std.testing.allocator;
    const loader = jamtestnet.jamzig.Loader(JAMDUNA_PARAMS){};
    try runStateTransitionTests(
        JAMDUNA_PARAMS,
        loader.loader(),
        allocator,
        "src/jamtestnet/teams/jamzig/safrole/state_transitions",
    );
}

/// Run state transition tests using vectors from the specified directory
pub fn runStateTransitionTests(
    comptime params: jam_params.Params,
    loader: jamtestnet.Loader,
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

        var state_transition = try loader.loadTestVector(allocator, state_transition_vector.bin.path);
        defer state_transition.deinit(allocator);

        // First validate the roots
        var pre_state_mdict = try state_transition.preStateAsMerklizationDict(allocator);
        defer pre_state_mdict.deinit();

        // std.debug.print("{}", .{types.fmt.format(pre_state_mdict)});
        std.debug.print("{}", .{types.fmt.format(state_transition.block())});

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

            var current_state_mdict = try current_state.?.buildStateMerklizationDictionary(allocator);
            defer current_state_mdict.deinit();
            var genesis_state_diff = try current_state_mdict.diff(&dict);
            defer genesis_state_diff.deinit();

            if (genesis_state_diff.has_changes()) {
                std.debug.print("Genesis State Reconstruction Failed. Dict -> Reconstruct -> Dict not symmetrical. Check state encode and decode\n", .{});
                std.debug.print("{}", .{genesis_state_diff});
                return error.GenesisStateDiff;
            }
        }

        // Ensure we are starting with the same roots.
        const pre_state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.preStateRoot(),
            &pre_state_root,
        );

        // std.debug.print("Executing state transition...\n", .{});
        var transition = try stf.stateTransition(
            params,
            allocator,
            &current_state.?,
            &state_transition.block(),
        );
        defer transition.deinitHeap();

        // Merge transition into base state
        try transition.mergePrimeOntoBase();

        // Log block information for debugging
        @import("sequoia.zig").logging.printBlockEntropyDebug(
            JAMDUNA_PARAMS,
            &state_transition.block(),
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

            var state_diff = try @import("tests/state_diff.zig").JamStateDiff(params).build(allocator, &current_state.?, &expected_state);
            defer state_diff.deinit();

            state_diff.printToStdErr();

            // std.debug.print("{}", .{current_state.?});

            return error.UnexpectedStateDiff;
        }

        // Validate state root
        const state_root = try current_state.?.buildStateRoot(allocator);
        try std.testing.expectEqualSlices(
            u8,
            &state_transition.postStateRoot(),
            &state_root,
        );
    }
}
