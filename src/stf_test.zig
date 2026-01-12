
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
    const allocator = testing.allocator;


    const seed: [32]u8 = [_]u8{42} ** 32;
    var prng = std.Random.ChaCha.init(seed);
    var rng = prng.random();

    const config = try sequoia.GenesisConfig(jam_params.TINY_PARAMS).buildWithRng(allocator, &rng);

    var builder = try sequoia.BlockBuilder(jam_params.TINY_PARAMS).init(allocator, config, &rng);
    defer builder.deinit();

    const num_blocks = 64;

    const current_state = &builder.state;


    const io = @import("io.zig");
    var sequential_executor = try io.SequentialExecutor.init(testing.allocator);
    defer sequential_executor.deinit();
    var block_importer = block_import.BlockImporter(io.SequentialExecutor, jam_params.TINY_PARAMS).init(&sequential_executor, allocator);

    var previous_state = try current_state.deepClone(allocator);
    defer previous_state.deinit(allocator);

    for (0..num_blocks) |block_idx| {
        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        sequoia.logging.printBlockEntropyDebug(jam_params.TINY_PARAMS, &block, current_state);

        var result = try block_importer.importBlockBuildingRoot(
            current_state,
            &block,
        );
        defer result.deinit();
        try result.commit();

        _ = block_idx;

        previous_state.deinit(allocator);
        previous_state = try current_state.deepClone(allocator);
    }
}

test "IO executor integration: sequential vs parallel execution" {
    const allocator = testing.allocator;
    const io = @import("io.zig");

    const seed: [32]u8 = [_]u8{42} ** 32;
    var prng = std.Random.ChaCha.init(seed);
    var rng = prng.random();

    const config = try sequoia.GenesisConfig(jam_params.TINY_PARAMS).buildWithRng(allocator, &rng);
    var builder = try sequoia.BlockBuilder(jam_params.TINY_PARAMS).init(allocator, config, &rng);
    defer builder.deinit();

    {
        var sequential_executor = try io.SequentialExecutor.init(testing.allocator);
        defer sequential_executor.deinit();
        var seq_importer = block_import.BlockImporter(io.SequentialExecutor, jam_params.TINY_PARAMS).init(&sequential_executor, allocator);

        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        var seq_result = try seq_importer.importBlockBuildingRoot(&builder.state, &block);
        defer seq_result.deinit();

        try seq_result.commit();

        try testing.expect(@intFromPtr(seq_result.state_transition) != 0);
    }

    {
        var parallel_executor = try io.ThreadPoolExecutor.initWithThreadCount(allocator, 2);
        defer parallel_executor.deinit();

        var par_importer = block_import.BlockImporter(io.ThreadPoolExecutor, jam_params.TINY_PARAMS).init(&parallel_executor, allocator);

        var block = try builder.buildNextBlock();
        defer block.deinit(allocator);

        var par_result = try par_importer.importBlockBuildingRoot(&builder.state, &block);
        defer par_result.deinit();

        try par_result.commit();

        try testing.expect(@intFromPtr(par_result.state_transition) != 0);
    }
}
