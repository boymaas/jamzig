const std = @import("std");

const clap = @import("clap");

const pvm_fuzzer = @import("pvm_test/fuzzer/fuzzer.zig");
const PVMFuzzer = pvm_fuzzer.PVMFuzzer;
const FuzzConfig = pvm_fuzzer.FuzzConfig;

fn showHelp(params: anytype) !void {
    std.debug.print(
        \\jamzig-pvm-fuzzer: A fuzzing tool for testing the Polka Virtual Machine
        \\Generates random PVM programs and executes them to find potential issues
        \\
        \\
    , .{});
    try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{ .spacing_between_parameters = 0 });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arguments parsing
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-v, --verbose             Enable verbose output
        \\-s, --seed <u64>          Initial random seed (default: timestamp)
        \\-c, --cases <u32>         Number of test cases to run (default: 50000)
        \\-C, --start-case <u32>    First case to run
        \\-g, --max-gas <u32>       Maximum gas per test case (default: 1000000)
        \\-b, --max-blocks <u32>    Maximum number of basic blocks per program (default: 32)
        \\-S, --test-seed <u64>     Rerun a single testcase with this seed
        \\-m, --mut-prob <usize>       Program mutation probability (0-1K, default: 10)
        \\-f, --flip-prob <usize>      Bit flip probability (0-1K, default: 1)
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        try showHelp(params);
        std.process.exit(1);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return showHelp(params);

    const config = FuzzConfig{
        .initial_seed = if (res.args.seed) |seed| seed else @as(u64, @intCast(std.time.timestamp())),
        .num_cases = if (res.args.cases) |cases| cases else 50000,
        .start_case = if (res.args.@"start-case") |start_case| start_case else 0,
        .max_gas = if (res.args.@"max-gas") |gas| gas else 1000000,
        .max_instruction_count = if (res.args.@"max-blocks") |blocks| blocks else 32,
        .verbose = res.args.verbose != 0,
        .mutation = .{
            .program_mutation_probability = if (res.args.@"mut-prob") |prob| prob else 10,
            .bit_flip_probability = if (res.args.@"flip-prob") |prob| prob else 1,
        },
    };

    // Initialize and run fuzzer
    var fuzzer = try PVMFuzzer.init(allocator, config);
    defer fuzzer.deinit();

    // Print configuration
    if (res.args.@"test-seed") |test_case_seed| {
        std.debug.print("\nRunning single test case with seed: {d}\n", .{test_case_seed});
        _ = try fuzzer.runSingleTest(test_case_seed);
        return;
    }

    // Print configuration
    std.debug.print("PVM Fuzzer Configuration:\n", .{});
    std.debug.print("Initial Seed: {d}\n", .{config.initial_seed});
    std.debug.print("Number of Cases: {d}\n", .{config.num_cases});
    std.debug.print("Start case: {d}\n", .{config.start_case});
    std.debug.print("Max Gas: {d}\n", .{config.max_gas});
    std.debug.print("Max Instructions: {d}\n", .{config.max_instruction_count});
    std.debug.print("Verbose: {}\n", .{config.verbose});
    std.debug.print("Mutation Probability: {d}/1M\n", .{config.mutation.program_mutation_probability});
    std.debug.print("Bit Flip Probability: {d}/1K\n\n", .{config.mutation.bit_flip_probability});

    var run = try fuzzer.run();

    // Print results
    const stats = run.results.getStats();
    const init_stats = run.init_errors.getStats();

    std.debug.print("\nFuzzing Complete!\n", .{});
    std.debug.print("==================== Results:\n", .{});
    std.debug.print("  Total Cases  : {d}\n", .{stats.total_cases});
    std.debug.print("  Mutated Cases: {d}\n", .{init_stats.mutated_cases});
    std.debug.print("  Avg Gas Used : {d}\n", .{stats.avgGas()});
    try run.results.writeExecutionStats(std.io.getStdErr().writer());

    std.debug.print("\n\n==================== Execution errors\n", .{});
    try stats.error_stats.writeErrorCounts(std.io.getStdErr().writer());

    std.debug.print("\n\n==================== Execution errors after mutation\n", .{});
    try stats.error_stats_mutated.writeErrorCounts(std.io.getStdErr().writer());

    std.debug.print("\n\n==================== Init Errors:\n", .{});
    try init_stats.error_stats.writeErrorCounts(std.io.getStdErr().writer());

    std.debug.print("\n\n==================== Init Errors after mutation\n", .{});
    try init_stats.error_stats_mutated.writeErrorCounts(std.io.getStdErr().writer());
}
