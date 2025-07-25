const std = @import("std");
const testing = std.testing;

const block_import = @import("block_import.zig");
const stf = @import("stf.zig");
const sequoia = @import("sequoia.zig");
const state = @import("state.zig");
const jam_params = @import("jam_params.zig");

const diffz = @import("tests/diffz.zig");
const state_diff = @import("tests/state_diff.zig");

test "sequoia: State transition with sequoia-generated blocks" {
    // Initialize test environment
    const allocator = testing.allocator;

    // Create initial state using tiny test parameters

    // Setup our seeded Rng
    const seed: [32]u8 = [_]u8{42} ** 32;
    var prng = std.Random.ChaCha.init(seed);
    var rng = prng.random();

    // Create genesis state
    const config = try sequoia.GenesisConfig(jam_params.TINY_PARAMS).buildWithRng(allocator, &rng);

    // Create block builder
    var builder = try sequoia.BlockBuilder(jam_params.TINY_PARAMS).init(allocator, config, &rng);
    defer builder.deinit();

    // Test multiple block transitions
    const num_blocks = 64;

    // Let's give access to the current state
    const current_state = &builder.state;

    // sequoia.logging.printStateDebug(jam_params.TINY_PARAMS, current_state);

    var block_importer = block_import.BlockImporter(jam_params.TINY_PARAMS).init(allocator);

    // Keep a copy of the previous state for comparison
    var previous_state = try current_state.deepClone(allocator);
    defer previous_state.deinit(allocator);

    // Generate and process multiple blocks
    for (0..num_blocks) |block_idx| {
        // Build next block
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Log block information for debugging
        sequoia.logging.printBlockEntropyDebug(jam_params.TINY_PARAMS, &block, current_state);

        // Perform state transition
        var result = try block_importer.importBlock(current_state, &block);
        defer result.deinit();
        try result.commit();

        _ = block_idx;
        // // Print state diff after processing each block
        // var jam_state_diff = try state_diff.JamStateDiff(jam_params.TINY_PARAMS).build(allocator, &previous_state, current_state);
        // defer jam_state_diff.deinit();
        //
        // if (jam_state_diff.hasChanges()) {
        //     std.debug.print("\n========== State changes after block {d} ==========\n", .{block_idx});
        //     jam_state_diff.printToStdErr();
        // } else {
        //     std.debug.print("\n========== No state changes after block {d} ==========\n", .{block_idx});
        // }

        // Update previous state for next iteration
        previous_state.deinit(allocator);
        previous_state = try current_state.deepClone(allocator);
    }
}
