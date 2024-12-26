const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_dict = @import("state_dictionary.zig");
const codec = @import("codec.zig");
const services = @import("services.zig");

const jam_params = @import("jam_params.zig");

const jamtestnet = @import("jamtestnet.zig");

const trace = @import("tracing.zig").scoped(.stf_test);

// we derive from the normal settings
// see: https://github.com/jam-duna/jamtestnet/blob/main/chainspecs.json#L2
const JAMDUNA_PARAMS = jam_params.Params{
    .epoch_length = 12,
    .ticket_submission_end_epoch_slot = 10,
    .validators_count = 6,
    .validators_super_majority = 5,
    .core_count = 2,
    .avail_bitfield_bytes = (2 + 7) / 8,
    // JAMDUNA changes
    .max_ticket_entries_per_validator = 3, // N
    .max_authorizations_queue_items = 6, // M
};

test "jamtestnet.jamduna: verifying state reconstruction" {
    const span = trace.span(.jamduna);
    defer span.deinit();

    // Get test allocator
    const allocator = testing.allocator;

    // Deserialize the state dictionary bin
    var state_transition = try jamtestnet.parsers.bin.state_transition.loadTestVector(
        JAMDUNA_PARAMS,
        allocator,
        "src/jamtestnet/data/safrole/state_transitions/425530_000.bin",
    );
    defer state_transition.deinit(allocator);

    var genesis_mdict = try state_transition.pre_state_as_merklization_dict(allocator);
    defer genesis_mdict.deinit();

    // Reonstruct state from state dict
    var genesis_state = try state_dict.reconstruct.reconstructState(JAMDUNA_PARAMS, allocator, &genesis_mdict);
    defer genesis_state.deinit(allocator);

    // Check the roots
    var parent_state_root = try genesis_state.buildStateRootWithConfig(allocator, .{ .include_preimage_timestamps = false });
    try std.testing.expectEqualSlices(
        u8,
        &parent_state_root,
        &state_transition.pre_state.state_root,
    );

    // NOTE: missing pre_image_lookups in the state dicts will add manuall

    // get the service account
    const service_account = genesis_state.delta.?.accounts.get(0x00).?;
    const storage_count = service_account.storage.count();
    const preimages_count = service_account.preimages.count();
    std.debug.print("\nService Account Stats:\n", .{});
    std.debug.print("  Storage entries: {d}\n", .{storage_count});
    std.debug.print("  Preimages entries: {d}\n\n", .{preimages_count});

    // JamDuna testblocks do no contain timestamps from the preimages
    var reconstructed_genesis_state_mdict = try genesis_state.buildStateMerklizationDictionaryWithConfig(
        allocator,
        .{ .include_preimage_timestamps = false },
    );
    defer reconstructed_genesis_state_mdict.deinit();

    // Lets see when we serialize the genesis mdict ourselves if we get the same mdict
    var genesis_state_diff = try genesis_mdict.diff(&reconstructed_genesis_state_mdict);
    defer genesis_state_diff.deinit();
    if (genesis_state_diff.has_changes()) {
        std.debug.print("\nDiff between reconstructed state and original state dictionary:\n(- means missing from reconstructed, + means extra in reconstructed)\n\n{any}\n", .{genesis_state_diff});

        for (genesis_state_diff.entries.items) |diff| {
            const key_type = @import("state_dictionary/key_type_detection.zig").detectKeyType(diff.key);
            std.debug.print("Key type: {s}, key: 0x{s}\n", .{ @tagName(key_type), std.fmt.fmtSliceHexLower(&diff.key) });
        }

        return error.InvalidGenesisState;
    }
}

test "jamtestnet.jamduna.state-transitions" {
    const allocator = std.testing.allocator;
    std.debug.print("\n=== Starting Safrole State Transitions Test ===\n", .{});

    var state_transition_vectors = try jamtestnet.state_transitions.collectStateTransitions("src/jamtestnet/data/safrole", allocator);
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
        std.debug.print("Block header slot: {d}\n", .{state_transition.block.header.slot});

        if (current_state == null) {
            std.debug.print("Initializing genesis state...\n", .{});
            var dict = try state_transition.pre_state_as_merklization_dict(allocator);
            defer dict.deinit();
            current_state = try state_dict.reconstruct.reconstructState(
                JAMDUNA_PARAMS,
                allocator,
                &dict,
            );
            std.debug.print("Beta {s}", .{current_state.?.beta.?});
            std.debug.print("Genesis state initialized\n", .{});
        }

        // std.debug.print("Current state {s}", .{current_state.?});

        std.debug.print("Executing state transition...\n", .{});
        var delta_state = try stf.stateTransition(
            JAMDUNA_PARAMS,
            allocator,
            &current_state.?,
            &state_transition.block,
        );
        defer delta_state.deinit(allocator);

        std.debug.print("Merging states...\n", .{});
        try current_state.?.merge(&delta_state, allocator);
        std.debug.print("State merge complete\n", .{});

        // std.debug.print("New state {s}", .{current_state.?});

        var current_state_mdict = try current_state.?.buildStateMerklizationDictionaryWithConfig(allocator, .{ .include_preimage_timestamps = false });
        defer current_state_mdict.deinit();

        var expected_state_mdict = try state_transition.post_state_as_merklization_dict(allocator);
        defer expected_state_mdict.deinit();

        var expected_state_diff = try current_state_mdict.diff(&expected_state_mdict);
        defer expected_state_diff.deinit();

        if (expected_state_diff.has_changes()) {
            // std.debug.print("State Diff: {}", .{expected_state_diff});

            var expected_state = try state_dict.reconstruct.reconstructState(JAMDUNA_PARAMS, allocator, &expected_state_mdict);
            defer expected_state.deinit(allocator);

            try @import("tests/diff.zig").printDiffBasedOnFormatToStdErr(allocator, &current_state.?, &expected_state);
            return error.UnexpectedStateDiff;
        }

        const state_root = try delta_state.buildStateRootWithConfig(allocator, .{ .include_preimage_timestamps = false });
        std.debug.print("New state root: {s}\n", .{std.fmt.fmtSliceHexLower(&state_root)});

        try std.testing.expectEqualSlices(u8, &state_root, &state_transition.post_state.state_root);
    }
    std.debug.print("\n=== Completed All State Transitions ===\n", .{});
}
