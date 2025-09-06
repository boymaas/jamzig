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

    // Use sequential executor for compatibility with existing test
    const io = @import("io.zig");
    var sequential_executor = try io.SequentialExecutor.init(testing.allocator);
    defer sequential_executor.deinit();
    var block_importer = block_import.BlockImporter(io.SequentialExecutor, jam_params.TINY_PARAMS).init(&sequential_executor, allocator);

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
        var result = try block_importer.importBlock(
            current_state,
            null, // TODO: CACHE current state root
            &block,
        );
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

test "IO executor integration: sequential vs parallel execution" {
    const allocator = testing.allocator;
    const io = @import("io.zig");

    // Setup test state similar to sequoia test
    const seed: [32]u8 = [_]u8{42} ** 32;
    var prng = std.Random.ChaCha.init(seed);
    var rng = prng.random();

    const config = try sequoia.GenesisConfig(jam_params.TINY_PARAMS).buildWithRng(allocator, &rng);
    var builder = try sequoia.BlockBuilder(jam_params.TINY_PARAMS).init(allocator, config, &rng);
    defer builder.deinit();

    // Test with sequential executor
    {
        var sequential_executor = try io.SequentialExecutor.init(testing.allocator);
        defer sequential_executor.deinit();
        var seq_importer = block_import.BlockImporter(io.SequentialExecutor, jam_params.TINY_PARAMS).init(&sequential_executor, allocator);

        // Build a test block
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Test sequential execution
        var seq_result = try seq_importer.importBlock(&builder.state, null, &block);
        defer seq_result.deinit();

        // Commit the sequential result to advance the state
        try seq_result.commit();

        // Verify it succeeded (state_transition is a valid pointer)
        try testing.expect(@intFromPtr(seq_result.state_transition) != 0);
    }

    // Test with parallel executor
    {
        var parallel_executor = try io.ThreadPoolExecutor.initWithThreadCount(allocator, 2);
        defer parallel_executor.deinit();

        var par_importer = block_import.BlockImporter(io.ThreadPoolExecutor, jam_params.TINY_PARAMS).init(&parallel_executor, allocator);

        // Build another test block (state has advanced from the sequential test)
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        // Test parallel execution
        var par_result = try par_importer.importBlock(&builder.state, null, &block);
        defer par_result.deinit();

        // Commit the parallel result
        try par_result.commit();

        // Verify it succeeded (state_transition is a valid pointer)
        try testing.expect(@intFromPtr(par_result.state_transition) != 0);
    }
}
