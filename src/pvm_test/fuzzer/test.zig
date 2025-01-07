const std = @import("std");
const testing = std.testing;

const PVMFuzzer = @import("fuzzer.zig").PVMFuzzer;
const FuzzConfig = @import("fuzzer.zig").FuzzConfig;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const InstructionGenerator = @import("instruction_generator.zig").InstructionGenerator;
const MemoryConfigGenerator = @import("memory_config_generator.zig").MemoryConfigGenerator;

test "PVM Fuzzer - Basic functionality" {
    const config = FuzzConfig{
        .initial_seed = 42,
        .num_cases = 10,
        .max_gas = 10000,
        .max_blocks = 8,
        .verbose = false,
    };

    var fuzzer = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer.deinit();

    try fuzzer.run();

    const stats = fuzzer.getStats();
    try testing.expect(stats.total_cases == 10);
    try testing.expect(stats.total_cases == stats.successful + stats.traps + stats.errors);
}

test "PVM Fuzzer - Program generation" {
    var seed_gen = SeedGenerator.init(42);
    var program_gen = ProgramGenerator.init(testing.allocator, &seed_gen);
    defer program_gen.deinit();

    var program = try program_gen.generate(4);
    defer program.deinit(testing.allocator);

    try testing.expect(program.code.len > 0);
    try testing.expect(program.mask.len > 0);
    try testing.expect(program.jump_table.len > 0);
}

test "PVM Fuzzer - Memory configuration" {
    var seed_gen = SeedGenerator.init(42);
    var memory_gen = MemoryConfigGenerator.init(testing.allocator, &seed_gen);

    const configs = try memory_gen.generatePageConfigs();
    defer testing.allocator.free(configs);

    // Verify no overlapping pages
    for (configs[0 .. configs.len - 1], 0..) |config, i| {
        const next = configs[i + 1];
        try testing.expect(config.address + config.length <= next.address);
    }

    // Verify alignments
    for (configs) |config| {
        try testing.expect(config.address % 8 == 0);
        try testing.expect(config.length % 8 == 0);
    }
}

test "PVM Fuzzer - Different seeds produce different programs" {
    var fuzzer1 = try PVMFuzzer.init(testing.allocator, .{ .initial_seed = 1, .num_cases = 1 });
    defer fuzzer1.deinit();
    try fuzzer1.run();

    var fuzzer2 = try PVMFuzzer.init(testing.allocator, .{ .initial_seed = 2, .num_cases = 1 });
    defer fuzzer2.deinit();
    try fuzzer2.run();

    const results1 = fuzzer1.getResults();
    const results2 = fuzzer2.getResults();

    try testing.expect(results1[0].seed != results2[0].seed);
}

test "PVM Fuzzer - Gas consumption" {
    const config = FuzzConfig{
        .initial_seed = 42,
        .num_cases = 5,
        .max_gas = 1000,
        .max_blocks = 4,
        .verbose = false,
    };

    var fuzzer = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer.deinit();
    try fuzzer.run();

    const results = fuzzer.getResults();
    for (results) |result| {
        try testing.expect(result.gas_used >= 0);
        try testing.expect(result.gas_used <= config.max_gas);
    }
}

test "PVM Fuzzer - Deterministic execution" {
    const config = FuzzConfig{
        .initial_seed = 42,
        .num_cases = 5,
        .max_gas = 1000,
        .verbose = false,
    };

    // Run fuzzer twice with same seed
    var fuzzer1 = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer1.deinit();
    try fuzzer1.run();
    const results1 = fuzzer1.getResults();

    var fuzzer2 = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer2.deinit();
    try fuzzer2.run();
    const results2 = fuzzer2.getResults();

    // Verify results are identical
    for (results1, 0..) |result1, i| {
        const result2 = results2[i];
        try testing.expectEqual(result1.seed, result2.seed);
        try testing.expectEqual(result1.status, result2.status);
        try testing.expectEqual(result1.gas_used, result2.gas_used);
    }
}
