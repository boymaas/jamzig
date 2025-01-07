const std = @import("std");
const Allocator = std.mem.Allocator;
const PVM = @import("../../pvm.zig").PVM;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const InstructionGenerator = @import("instruction_generator.zig").InstructionGenerator;
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
    status: PVM.Status,
    gas_used: i64,
    error_data: ?PVM.ErrorData,
};

pub const PVMFuzzer = struct {
    allocator: Allocator,
    config: FuzzConfig,
    seed_gen: SeedGenerator,
    program_gen: ProgramGenerator,
    instruction_gen: InstructionGenerator,
    memory_gen: MemoryConfigGenerator,
    results: std.ArrayList(FuzzResult),

    const Self = @This();

    pub fn init(allocator: Allocator, config: FuzzConfig) !Self {
        var seed_gen = SeedGenerator.init(config.initial_seed);

        return Self{
            .allocator = allocator,
            .config = config,
            .seed_gen = seed_gen,
            .program_gen = ProgramGenerator.init(allocator, &seed_gen),
            .instruction_gen = InstructionGenerator.init(&seed_gen),
            .memory_gen = MemoryConfigGenerator.init(allocator, &seed_gen),
            .results = std.ArrayList(FuzzResult).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.program_gen.deinit();
        self.results.deinit();
    }

    pub fn run(self: *Self) !void {
        var test_count: u32 = 0;
        while (test_count < self.config.num_cases) : (test_count += 1) {
            if (self.config.verbose) {
                std.debug.print("Running test case {d}/{d} with seed {d}\n", .{ test_count + 1, self.config.num_cases, self.seed_gen.seed });
            }

            const result = try self.runSingleTest();
            try self.results.append(result);

            if (self.config.verbose) {
                self.printTestResult(test_count, result);
            }
        }
    }

    fn runSingleTest(self: *Self) !FuzzResult {
        // Generate program
        const num_blocks = self.seed_gen.randomIntRange(u32, 1, self.config.max_blocks);
        var program = try self.program_gen.generate(num_blocks);
        defer program.deinit(self.allocator);

        // Generate memory configuration
        const page_configs = try self.memory_gen.generatePageConfigs();
        defer self.allocator.free(page_configs);

        // Initialize PVM
        var pvm = try PVM.init(self.allocator, program.code, self.config.max_gas);
        defer pvm.deinit();

        // Set up memory pages
        try pvm.setPageMap(page_configs);

        // Initialize memory contents
        for (page_configs) |config| {
            const contents = try self.memory_gen.generatePageContents(config.length);
            defer self.allocator.free(contents);
            try pvm.writeMemory(config.address, contents);
        }

        // Run program and collect results
        const initial_gas = pvm.gas;
        const status = pvm.run();
        const gas_used = initial_gas - pvm.gas;

        return FuzzResult{
            .seed = self.seed_gen.seed,
            .status = status,
            .gas_used = gas_used,
            .error_data = pvm.error_data,
        };
    }

    fn printTestResult(_: *Self, test_number: u32, result: FuzzResult) void {
        const color = switch (result.status) {
            .play, .halt => "\x1b[32m", // green
            .trap => "\x1b[33m", // yellow
            else => "\x1b[31m", // red
        };

        std.debug.print("{s}Test {d}: Status={any}, Gas={d}, Seed={d}\x1b[0m\n", .{ color, test_number + 1, result.status, result.gas_used, result.seed });

        if (result.error_data) |error_data| {
            std.debug.print("  Error data: {any}\n", .{error_data});
        }
    }

    pub fn getResults(self: *Self) []const FuzzResult {
        return self.results.items;
    }

    const Stats = struct {
        total_cases: usize,
        successful: usize,
        traps: usize,
        errors: usize,
        avg_gas: i64,
    };

    /// Get statistics about the test results
    pub fn getStats(self: *Self) Stats {
        var stats = Stats{
            .total_cases = self.results.items.len,
            .successful = 0,
            .traps = 0,
            .errors = 0,
            .avg_gas = 0,
        };

        var total_gas: i64 = 0;
        for (self.results.items) |result| {
            switch (result.status) {
                .play, .halt => stats.successful += 1,
                .trap => stats.traps += 1,
                else => stats.errors += 1,
            }
            total_gas += result.gas_used;
        }

        if (stats.total_cases > 0) {
            stats.avg_gas = @divTrunc(total_gas, @as(i64, @intCast(stats.total_cases)));
        }

        return stats;
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
