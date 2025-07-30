const std = @import("std");
const jam_params = @import("jam_params.zig");
const sequoia = @import("sequoia.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const codec = @import("codec.zig");
const state_dictionary = @import("state_dictionary.zig");
const jamtestnet = @import("jamtestnet.zig");
const jamtestnet_export = @import("jamtestnet/export.zig");

const stf = @import("stf.zig");

const StateTransition = jamtestnet_export.StateTransition;
const KeyVal = jamtestnet_export.KeyVal;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup seeded RNG for deterministic test vectors
    const seed: [32]u8 = [_]u8{42} ** 32;
    var prng = std.Random.ChaCha.init(seed);
    var rng = prng.random();

    // Params
    const PARAMS = jamtestnet.W3F_PARAMS;

    // Create genesis config and block builder
    const config = try sequoia.GenesisConfig(PARAMS).buildWithRng(allocator, &rng);
    var builder = try sequoia.BlockBuilder(PARAMS).init(allocator, config, &rng);
    defer builder.deinit();

    const output_dir = "jamtestnet_export_output";
    const num_blocks = 64;

    std.debug.print("Generating {d} blocks...\n", .{num_blocks});

    // Generate and process multiple blocks
    for (0..num_blocks) |_| {
        var pre_state = try builder.state.deepClone(allocator);
        defer pre_state.deinit(allocator);

        // Build next block
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Perform state transition
        var state_transition = try stf.stateTransition(PARAMS, allocator, &builder.state, &block);
        defer state_transition.destroy(allocator);

        try state_transition.mergePrimeOntoBase();

        // Log block information for debugging
        sequoia.logging.printBlockEntropyDebug(
            PARAMS,
            &block,
            &builder.state,
        );

        var transition = try jamtestnet_export.buildStateTransition(
            PARAMS,
            allocator,
            &pre_state,
            block,
            &builder.state,
        );
        defer transition.deinit(allocator);

        try jamtestnet_export.writeStateTransition(
            PARAMS,
            allocator,
            transition,
            output_dir,
        );
    }
}
