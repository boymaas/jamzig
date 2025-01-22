const std = @import("std");
const testing = std.testing;

const PVMFuzzer = @import("fuzzer.zig").PVMFuzzer;
const FuzzConfig = @import("fuzzer.zig").FuzzConfig;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;

test "pvm:fuzzer:run" {
    const config = FuzzConfig{
        .initial_seed = 0,
        .num_cases = 10,
        .max_gas = 20,
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
