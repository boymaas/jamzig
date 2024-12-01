const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const codec = @import("codec.zig");

const jam_params = @import("jam_params.zig");

const jamtestnet_traces = @import("stf_test/jamtestnet_traces.zig");

const state_dict_reconstruct = @import("state_dictionary/reconstruct.zig");

const buildGenesisState = @import("stf_test/jamtestnet_genesis.zig").buildGenesisState;
const jamtestnet = @import("stf_test/jamtestnet.zig");

test "jamtestnet.jamduna: safrole import" {
    // we derive from the normal settings
    const JAMDUNA_PARAMS = jam_params.Params{
        .epoch_length = 12,
        .ticket_submission_end_epoch_slot = 10,
        .validators_count = 6,
        .validators_super_majority = 5,
        .core_count = 2,
        .avail_bitfield_bytes = (2 + 7) / 8,
        // JAMDUNA changes
        .max_ticket_entries_per_validator = 3, // N
    };

    // Get test allocator
    const allocator = testing.allocator;

    // Genesis state
    var genesis_state_dict = try jamtestnet_traces.loadStateDictionaryBin(allocator, "src/stf_test/jamtestnet/traces/safrole/jam_duna/traces/genesis.bin");
    defer genesis_state_dict.deinit();
    var genesis_jam_state = try state_dict_reconstruct.reconstructState(JAMDUNA_PARAMS, allocator, &genesis_state_dict);
    defer genesis_jam_state.deinit(allocator);

    // Get ordered block files
    var jam_state = try buildGenesisState(JAMDUNA_PARAMS, allocator, @embedFile("stf_test/jamtestnet/traces/safrole/jam_duna/state_snapshots/genesis.json"));
    defer jam_state.deinit(allocator);

    var parent_state_dict = try jam_state.buildStateMerklizationDictionary(allocator);
    defer parent_state_dict.deinit();

    // load the expecte genesis state
    var expected_genesis_state_dict = try jamtestnet.loadStateDictionaryDump(
        allocator,
        "src/stf_test/jamtestnet/traces/safrole/jam_duna/traces/genesis.json",
    );
    defer expected_genesis_state_dict.deinit();

    var genesis_state_diff = try parent_state_dict.diff(&expected_genesis_state_dict);
    defer genesis_state_diff.deinit();
    if (genesis_state_diff.has_changes()) {
        std.debug.print("\nGenesis State diff other=expected:\n\n{any}\n", .{genesis_state_diff});
        return error.InvalidGenesisState;
    }

    var parent_state_root = try jam_state.buildStateRoot(allocator);

    var outputs = try jamtestnet.collectJamOutputs("src/stf_test/jamtestnet/traces/safrole/jam_duna/", allocator);
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

        var new_state = try stf.stateTransition(JAMDUNA_PARAMS, allocator, &jam_state, &block.value);
        defer new_state.deinit(allocator);

        const state_root = try new_state.buildStateRoot(allocator);
        std.debug.print("state root 0x{s}", .{std.fmt.fmtSliceHexLower(&state_root)});

        std.debug.print(" STF \x1b[32mOK\x1b[0m\n", .{});

        try jam_state.merge(&new_state, allocator);

        parent_state_dict.deinit();
        parent_state_dict = try jam_state.buildStateMerklizationDictionary(allocator);
    }
}
