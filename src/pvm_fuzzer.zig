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
        \\-c, --cases <u32>         Number of test cases to run (default: 1000)
        \\-g, --max-gas <i64>       Maximum gas per test case (default: 1000000)
        \\-b, --max-blocks <u32>    Maximum number of basic blocks per program (default: 32)
        \\
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
        .num_cases = if (res.args.cases) |cases| cases else 1000,
        .max_gas = if (res.args.@"max-gas") |gas| gas else 1000000,
        .max_blocks = if (res.args.@"max-blocks") |blocks| blocks else 32,
        .verbose = res.args.verbose != 0,
    };

    // Print configuration
    std.debug.print("PVM Fuzzer Configuration:\n", .{});
    std.debug.print("Initial Seed: {d}\n", .{config.initial_seed});
    std.debug.print("Number of Cases: {d}\n", .{config.num_cases});
    std.debug.print("Max Gas: {d}\n", .{config.max_gas});
    std.debug.print("Max Blocks: {d}\n", .{config.max_blocks});
    std.debug.print("Verbose: {}\n\n", .{config.verbose});

    // Initialize and run fuzzer
    var fuzzer = try PVMFuzzer.init(allocator, config);
    defer fuzzer.deinit();

    var result = try fuzzer.run();
    defer result.deinit();

    // Print results
    const stats = result.getStats();
    std.debug.print("\nFuzzing Complete!\n", .{});
    std.debug.print("Results:\n", .{});
    std.debug.print("  Total Cases: {d}\n", .{stats.total_cases});
    std.debug.print("  Successful: {d} ({d}%)\n", .{ stats.successful, (stats.successful * 100) / stats.total_cases });
    std.debug.print("  Errors: {d} ({d}%)\n", .{ stats.errors, (stats.errors * 100) / stats.total_cases });
    std.debug.print("  Average Gas Used: {d}\n", .{stats.avg_gas});
}
