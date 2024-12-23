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

test "jamtestnet.jamduna: safrole import" {
    const span = trace.span(.jamduna);
    defer span.deinit();

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

    // NOTE: missing pre_image_lookups in the state dicts will add manuall

    // get the service account
    const service_account = genesis_state.delta.?.accounts.get(0x00).?;
    const storage_count = service_account.storage.count();
    const preimages_count = service_account.preimages.count();
    std.debug.print("\nService Account Stats:\n", .{});
    std.debug.print("  Storage entries: {d}\n", .{storage_count});
    std.debug.print("  Preimages entries: {d}\n\n", .{preimages_count});

    var parent_state_dict = try genesis_state.buildStateMerklizationDictionary(allocator);
    defer parent_state_dict.deinit();

    var genesis_state_diff = try parent_state_dict.diff(&genesis_mdict);
    defer genesis_state_diff.deinit();
    if (genesis_state_diff.has_changes()) {
        std.debug.print("\nGenesis State diff other=expected:\n\n{any}\n", .{genesis_state_diff});
        return error.InvalidGenesisState;
    }

    var parent_state_root = try genesis_state.buildStateRoot(allocator);

    var outputs = try jamtestnet.collector.collectJamOutputs("src/jamtestnet/data/traces/safrole/jam_duna/", allocator);
    defer outputs.deinit(allocator);

    std.debug.print("\n", .{});
    for (outputs.items()) |output| {
        std.debug.print("decode {s} => ", .{output.block.bin.name});

        // Slurp the binary file
        var block_bin = try output.block.bin.slurp(allocator);
        defer block_bin.deinit();

        // Now decode the block
        const block = try codec.deserialize(
            types.Block,
            JAMDUNA_PARAMS,
            allocator,
            block_bin.buffer,
        );
        defer block.deinit();

        if (std.mem.eql(u8, &block.value.header.parent_state_root, &parent_state_root)) {
            std.debug.print(" parent roots \x1b[32mmatch\x1b[0m ", .{});
        } else {
            std.debug.print("\n\nparent roots \x1b[31mdo not match\x1b[0m (me: 0x{s}, trace: 0x{s})\n", .{
                std.fmt.fmtSliceHexLower(&parent_state_root),
                std.fmt.fmtSliceHexLower(&block.value.header.parent_state_root),
            });

            std.debug.print("\nParent State Dictionary:\n{any}\n", .{parent_state_dict});

            var expected_state_dict = try output.parseTraceJson(allocator);
            defer expected_state_dict.deinit();

            std.debug.print("\nExpected State Dictionary:\n{any}\n", .{expected_state_dict});

            var delta = try expected_state_dict.diff(&parent_state_dict);
            defer delta.deinit();
            std.debug.print("\n State diff:\n{any}\n", .{delta});

            return error.ParentStateRootsDoNotMatch;
        }
        parent_state_root = block.value.header.parent_state_root;

        std.debug.print("block {} ..", .{block.value.header.slot});

        var new_state = try stf.stateTransition(JAMDUNA_PARAMS, allocator, &genesis_state, &block.value);
        defer new_state.deinit(allocator);

        const state_root = try new_state.buildStateRoot(allocator);
        std.debug.print("state root 0x{s}", .{std.fmt.fmtSliceHexLower(&state_root)});

        std.debug.print(" STF \x1b[32mOK\x1b[0m\n", .{});

        try genesis_state.merge(&new_state, allocator);

        parent_state_dict.deinit();
        parent_state_dict = try genesis_state.buildStateMerklizationDictionary(allocator);
    }
}
