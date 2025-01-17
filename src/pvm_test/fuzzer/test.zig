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
        .num_cases = 10,
        .max_gas = 10000,
        .max_instruction_count = 8,
        .verbose = true,
    };

    var fuzzer = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer.deinit();

    var results = try fuzzer.run();

    const stats = results.getStats();
    try testing.expectEqual(stats.total_cases, 10);
    try testing.expectEqual(stats.total_cases, stats.successful + stats.errors);
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
