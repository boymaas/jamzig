const std = @import("std");
const Allocator = std.mem.Allocator;
const PVM = @import("../../pvm.zig").PVM;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const MemoryConfigGenerator = @import("memory_config_generator.zig").MemoryConfigGenerator;

pub const FuzzConfig = struct {
    /// Starting seed for the random number generator
    initial_seed: u64 = 0,
    /// Number of test cases to run
    num_cases: u32 = 1000,
    /// Maximum gas for each test case
    max_gas: i64 = 1000000,
    /// Maximum number of basic blocks per program
    max_blocks: u32 = 32,
    /// Whether to print verbose output
    verbose: bool = false,
};

pub const FuzzResult = struct {
    seed: u64,
    status: ?PVM.Error,
    gas_used: i64,
    error_data: ?PVM.ErrorData,
};

pub const FuzzResults = struct {
    data: std.ArrayList(FuzzResult),

    const Stats = struct {
        total_cases: usize,
        successful: usize,
        errors: usize,
        avg_gas: i64,
    };

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .data = std.ArrayList(FuzzResult).init(allocator),
        };
    }

    /// Get statistics about the test results
    pub fn getStats(self: *@This()) Stats {
        var stats = Stats{
            .total_cases = self.data.items.len,
            .successful = 0,
            .errors = 0,
            .avg_gas = 0,
        };

        var total_gas: i64 = 0;
        for (self.data.items) |result| {
            if (result.status) |_| {
                stats.errors += 1;
            } else {
                stats.successful += 1;
            }
            total_gas += result.gas_used;
        }

        if (stats.total_cases > 0) {
            stats.avg_gas = @divTrunc(total_gas, @as(i64, @intCast(stats.total_cases)));
        }

        return stats;
    }

    pub fn deinit(self: *@This()) void {
        self.data.deinit();
        self.* = undefined;
    }
};

pub const PVMFuzzer = struct {
    allocator: Allocator,
    config: FuzzConfig,
    seed_gen: *SeedGenerator,

    const Self = @This();

    pub fn init(allocator: Allocator, config: FuzzConfig) !Self {
        const seed_gen = try allocator.create(SeedGenerator);
        seed_gen.* = SeedGenerator.init(config.initial_seed);

        return Self{
            .allocator = allocator,
            .config = config,
            .seed_gen = seed_gen,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self.seed_gen);
    }

    pub fn run(self: *Self) !FuzzResults {
        var results = FuzzResults.init(self.allocator);
        var test_count: u32 = 0;
        while (test_count < self.config.num_cases) : (test_count += 1) {
            if (self.config.verbose) {
                std.debug.print("Running test case {d}/{d} with seed {d}\n", .{ test_count + 1, self.config.num_cases, self.seed_gen.seed });
            }

            const result = try self.runSingleTest(self.seed_gen.randomSeed());
            try results.data.append(result);

            if (self.config.verbose) {
                self.printTestResult(test_count, result);
            }
        }
        return results;
    }

    fn runSingleTest(self: *Self, seed: u64) !FuzzResult {
        var seed_gen = SeedGenerator.init(seed);

        var program_gen = try ProgramGenerator.init(self.allocator, &seed_gen);
        var memory_gen = MemoryConfigGenerator.init(self.allocator, &seed_gen);

        // Generate program
        const num_blocks = seed_gen.randomIntRange(u32, 1, self.config.max_blocks);

        var program = try program_gen.generate(num_blocks);
        defer program.deinit(self.allocator);

        // Generate memory configuration
        const page_configs = try memory_gen.generatePageConfigs();
        defer self.allocator.free(page_configs);

        // Initialize PVM
        var pvm = try PVM.init(
            self.allocator,
            try program.getRawBytes(self.allocator),
            self.config.max_gas,
        );
        defer pvm.deinit();

        // Set up memory pages
        try pvm.setPageMap(page_configs);

        // Initialize memory contents
        for (page_configs) |config| {
            const contents = try memory_gen.generatePageContents(config.length);
            defer self.allocator.free(contents);
            try pvm.initMemory(config.address, contents);
        }

        // Run program and collect results
        const initial_gas = pvm.gas;
        const status = pvm.run();
        const gas_used = initial_gas - pvm.gas;

        return FuzzResult{
            .seed = seed,
            .status = if (status) null else |err| err,
            .gas_used = gas_used,
            .error_data = pvm.error_data,
        };
    }

    fn printTestResult(_: *Self, test_number: u32, result: FuzzResult) void {
        const color = if (result.status) |_|
            "\x1b[31m"
        else
            "\x1b[32m";

        std.debug.print("{s}Test {d}: Status={any}, Gas={d}, Seed={d}\x1b[0m\n", .{
            color,
            test_number + 1,
            result.status,
            result.gas_used,
            result.seed,
        });

        if (result.error_data) |error_data| {
            std.debug.print("  Error data: {any}\n", .{error_data});
        }
    }

    pub fn getResults(self: *Self) []const FuzzResult {
        return self.results.items;
    }
};

/// Run a simple fuzzing session with default configuration
pub fn fuzzSimple(allocator: Allocator) !void {
    var fuzzer = try PVMFuzzer.init(allocator, .{
        .initial_seed = 42,
        .num_cases = 100,
        .verbose = true,
    });
    defer fuzzer.deinit();

    try fuzzer.run();

    const stats = fuzzer.getStats();
    std.debug.print("\nFuzzing Results:\n", .{});
    std.debug.print("Total Cases: {d}\n", .{stats.total_cases});
    std.debug.print("Successful: {d}\n", .{stats.successful});
    std.debug.print("Traps: {d}\n", .{stats.traps});
    std.debug.print("Errors: {d}\n", .{stats.errors});
    std.debug.print("Average Gas: {d}\n", .{stats.avg_gas});
}
