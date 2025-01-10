const std = @import("std");
const testing = std.testing;

const PVMFuzzer = @import("fuzzer.zig").PVMFuzzer;
const FuzzConfig = @import("fuzzer.zig").FuzzConfig;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const MemoryConfigGenerator = @import("memory_config_generator.zig").MemoryConfigGenerator;

test "pvm:fuzzer:run" {
    const config = FuzzConfig{
        .initial_seed = 42,
        .num_cases = 100,
        .max_gas = 10000,
        .max_blocks = 8,
        .verbose = true,
    };

    var fuzzer = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer.deinit();

    var results = try fuzzer.run();
    defer results.deinit();

    const stats = results.getStats();
    try testing.expect(stats.total_cases == 100);
    try testing.expect(stats.total_cases == stats.successful + stats.traps + stats.errors);
}

test "pvm:fuzzer:memory_config_generator" {
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

test "pvm:fuzzer:deterministic_execution" {
    const config = FuzzConfig{
        .initial_seed = 42,
        .num_cases = 5,
        .max_gas = 1000,
        .verbose = false,
    };

    // Run fuzzer twice with same seed
    var fuzzer1 = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer1.deinit();
    const results1 = try fuzzer1.run();

    var fuzzer2 = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer2.deinit();
    const results2 = try fuzzer2.run();

    // Verify results are identical
    for (results1.data.items, 0..) |result1, i| {
        const result2 = results2.data.items[i];
        try testing.expectEqual(result1.seed, result2.seed);
        try testing.expectEqual(result1.status, result2.status);
        try testing.expectEqual(result1.gas_used, result2.gas_used);
    }
}
