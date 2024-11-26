const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const codec = @import("codec.zig");

const jam_params = @import("jam_params.zig");

const buildGenesisState = @import("stf_test/jamtestnet_genesis.zig").buildGenesisState;
const jamtestnet = @import("stf_test/jamtestnet.zig");

test "jamtestnet: jamduna safrole import" {
    // Get test allocator
    const allocator = testing.allocator;

    // Get ordered block files
    var jam_state = try buildGenesisState(jam_params.TINY_PARAMS, allocator, @embedFile("stf_test/genesis.json"));
    defer jam_state.deinit(allocator);

    var outputs = try jamtestnet.collectJamOutputs("src/stf_test/jamtestnet/traces/safrole/jam_duna/", allocator);
    defer outputs.deinit(allocator);

    std.debug.print("\n", .{});
    for (outputs.items()) |output| {
        std.debug.print("decode {s} => ", .{output.block.bin.name});

        // Slurp the binary file
        var block_bin = try output.block.bin.slurp(allocator);
        defer block_bin.deinit();

        // Now decode the block
        const block = try codec.deserialize(types.Block, jam_params.TINY_PARAMS, allocator, block_bin.buffer);
        defer block.deinit();

        std.debug.print("block {} ..", .{block.value.header.slot});

        var new_state = try stf.stateTransition(jam_params.TINY_PARAMS, allocator, &jam_state, &block.value);
        defer new_state.deinit(allocator);

        const state_root = try new_state.buildStateRoot(allocator);
        std.debug.print("state root 0x{s}", .{std.fmt.fmtSliceHexLower(&state_root)});

        std.debug.print(" STF \x1b[32mOK\x1b[0m\n", .{});

        try jam_state.merge(&new_state, allocator);
    }
}
