const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const sequoia = @import("sequoia.zig");
const state = @import("state.zig");
const jam_params = @import("jam_params.zig");

test "sequoia: State transition with sequoia-generated blocks" {
    // Initialize test environment
    const allocator = testing.allocator;

    // Create initial state using tiny test parameters
    var initial_state = try state.JamState(jam_params.TINY_PARAMS).init(allocator);
    defer initial_state.deinit(allocator);

    // Initialize required state components
    try initial_state.initTau();
    try initial_state.initEta();
    try initial_state.initBeta(allocator);
    try initial_state.initSafrole(allocator);
    try initial_state.initPsi(allocator);

    // Create block builder
    var builder = try sequoia.createTinyBlockBuilder(allocator, &initial_state);
    defer builder.deinit();

    // Test multiple block transitions
    var current_state = initial_state;
    const num_blocks = 5;

    // Generate and process multiple blocks
    for (0..num_blocks) |i| {
        // Build next block
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Log block information for debugging
        std.debug.print("\nProcessing block {d}:\n", .{i});
        std.debug.print("  Slot: {d}\n", .{block.header.slot});
        std.debug.print("  Author: {d}\n", .{block.header.author_index});

        // Perform state transition
        const new_state = try stf.stateTransition(jam_params.TINY_PARAMS, allocator, &current_state, &block);

        // Verify basic state transition properties
        try testing.expect(new_state.tau.? > current_state.tau.?);
        try testing.expect(new_state.beta.?.blocks.items.len > 0);

        // Clean up previous state if not the initial state
        if (@intFromPtr(&current_state) != @intFromPtr(&initial_state)) {
            current_state.deinit(allocator);
        }

        try current_state.merge(&new_state, allocator);
    }

    // Clean up final state if not the initial state
    if (@intFromPtr(&current_state) != @intFromPtr(&initial_state)) {
        current_state.deinit(allocator);
    }
}
