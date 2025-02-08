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

    _ = try fuzzer.run();
}

test "pvm:fuzzer:crosscheck" {
    const config = FuzzConfig{
        .initial_seed = 0,
        .num_cases = 1000,
        .max_gas = 20,
        .max_instruction_count = 8,
        .verbose = true,
        .enable_cross_check = true,
    };

    // RUST_LOG=polkavm=trace zig build test -Doptimize=Debug -Dtest-filter=pvm:fuzzer:crosscheck -Dtracing-scope=pvm -- --nocapture
    // @import("polkavm_ffi.zig").initLogging();

    var fuzzer = try PVMFuzzer.init(testing.allocator, config);
    defer fuzzer.deinit();

    _ = try fuzzer.run();
}
