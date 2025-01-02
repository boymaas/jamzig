const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const sequoia = @import("sequoia.zig");
const state = @import("state.zig");
const jam_params = @import("jam_params.zig");

const diffz = @import("tests/diffz.zig");

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
    const num_blocks = 512;

    // Let's give access to the current state
    var current_state = &builder.state;

    sequoia.logging.printStateDebug(jam_params.TINY_PARAMS, current_state);

    var debug_last_state: []u8 =
        try sequoia.logging.allocPrintStateDebug(jam_params.TINY_PARAMS, allocator, current_state);
    defer allocator.free(debug_last_state);

    // Generate and process multiple blocks
    for (0..num_blocks) |_| {
        // Build next block
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Log block information for debugging
        sequoia.logging.printBlockEntropyDebug(jam_params.TINY_PARAMS, &block, current_state);

        // Perform state transition
        var state_delta = try stf.stateTransition(jam_params.TINY_PARAMS, allocator, current_state, &block);
        defer state_delta.deinit(allocator);

        try current_state.merge(&state_delta, allocator);

        // Log block information for debugging after state transition
        const debug_current_state = try sequoia.logging.allocPrintStateDebug(jam_params.TINY_PARAMS, allocator, current_state);
        if (!std.mem.eql(u8, debug_last_state, debug_current_state)) {
            std.debug.print("\n\nState changes detected:\n", .{});
            try diffz.debugPrintDiffMarkChanges(allocator, debug_last_state, debug_current_state);
        }
        allocator.free(debug_last_state);
        debug_last_state = debug_current_state;
    }
}
