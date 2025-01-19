const std = @import("std");
const Allocator = std.mem.Allocator;
const PVM = @import("../../pvm.zig").PVM;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const MemoryConfigGenerator = @import("memory_config_generator.zig").MemoryConfigGenerator;

const trace = @import("../../tracing.zig").scoped(.pvm);

/// Configuration for program mutations
pub const MutationConfig = struct {
    /// Probability (0-1_000_000) that any given program will be mutated
    program_mutation_probability: usize = 10,
    /// For programs selected for mutation, probability (0-1_000) of each bit being flipped
    bit_flip_probability: usize = 1,
};

/// Mutates a program's raw bytes in-place according to the given configuration
pub fn mutateProgramBytes(
    bytes: []u8,
    config: MutationConfig,
    seed_gen: *SeedGenerator,
) void {
    const span = trace.span(.mutate_program);
    defer span.deinit();
    span.debug("Evaluating program mutation (length={d} bytes)", .{bytes.len});

    // First decide if we should mutate this program at all
    if (seed_gen.randomIntRange(usize, 0, 1_000_000) >= config.program_mutation_probability) {
        span.debug("Program skipped for mutation based on probability", .{});
        return;
    }

    // Calculate total number of bits to flip based on probability
    const total_bits = bytes.len * 8;
    const bits_to_flip = (total_bits * config.bit_flip_probability) / 1_000;

    var i: usize = 0;
    while (i < bits_to_flip) : (i += 1) {
        // Pick a random bit position in the entire range
        const bit_pos = seed_gen.randomIntRange(usize, 0, total_bits - 1);
        // Calculate which byte and bit to flip
        const byte_index = bit_pos >> 3; // divide by 8
        const bit_index = @as(u3, @intCast(bit_pos & 0x7)); // mod 8
        // Flip the bit
        bytes[byte_index] ^= @as(u8, 1) << bit_index;
    }
}

pub const FuzzConfig = struct {
    /// Starting seed for the random number generator
    initial_seed: u64 = 0,
    /// Number of test cases to run
    num_cases: u32 = 1000,
    /// Start art
    start_case: u32 = 0,
    /// Maximum gas for each test case
    max_gas: i64 = 100,
    /// Maximum number of basic blocks per program
    max_instruction_count: u32 = 32,
    /// Whether to print verbose output
    verbose: bool = false,
    /// Configuration for program mutations
    mutation: MutationConfig = .{},
};

pub const FuzzResult = struct {
    seed: u64,
    status: PVM.Error!void,
    gas_used: i64,
    was_mutated: bool,
    error_data: ?PVM.ErrorData,
    init_failed: bool = false,
};

const ErrorStats = struct {
    // Array to store counts for each error type
    counts: [error_count]usize,

    // Count of different error types for array size
    const error_count = blk: {
        var count: usize = 0;
        for (std.meta.fields(PVM.Error)) |_| {
            count += 1;
        }
        break :blk count;
    };

    pub fn init() ErrorStats {
        return .{
            .counts = [_]usize{0} ** error_count,
        };
    }

    pub fn recordError(self: *ErrorStats, err: PVM.Error) void {
        const index = comptime blk: {
            var error_map: [error_count]PVM.Error = undefined;
            var i: usize = 0;
            for (std.meta.fields(PVM.Error)) |field| {
                error_map[i] = @field(PVM.Error, field.name);
                i += 1;
            }
            break :blk error_map;
        };

        // Find the index of this error type
        for (index, 0..) |e, i| {
            if (err == e) {
                self.counts[i] += 1;
                return;
            }
        }
    }

    pub fn getErrorCount(self: *const ErrorStats, err: PVM.Error) usize {
        const index = comptime blk: {
            var error_map: [error_count]PVM.Error = undefined;
            var i: usize = 0;
            for (std.meta.fields(PVM.Error)) |field| {
                error_map[i] = @field(PVM.Error, field.name);
                i += 1;
            }
            break :blk error_map;
        };

        // Find the index of this error type
        for (index, 0..) |e, i| {
            if (err == e) {
                return self.counts[i];
            }
        }
        return 0;
    }

    pub fn writeErrorCounts(self: *const ErrorStats, writer: anytype) !void {
        const span = trace.span(.write_error_stats);
        defer span.deinit();
        span.debug("Writing error statistics", .{});

        const index = comptime blk: {
            var error_map: [error_count]PVM.Error = undefined;
            var i: usize = 0;
            for (std.meta.fields(PVM.Error)) |field| {
                error_map[i] = @field(PVM.Error, field.name);
                i += 1;
            }
            break :blk error_map;
        };

        try writer.writeAll("\nError Statistics:\n");
        for (index, 0..) |err, i| {
            if (self.counts[i] > 0) {
                try writer.print("    {s}: {d}\n", .{
                    @errorName(err),
                    self.counts[i],
                });
            }
        }
    }
};

pub const FuzzResults = struct {
    accumulated: Stats,

    const Stats = struct {
        total_cases: usize = 0,
        successful: usize = 0,
        errors: usize = 0,
        total_gas: i64 = 0,
        mutated_cases: usize = 0,
        init_failures: usize = 0,
        error_stats: ErrorStats = ErrorStats.init(),

        pub fn avgGas(self: *const @This()) usize {
            return @as(usize, @intCast(self.total_gas)) / self.total_cases;
        }
    };

    pub fn getStats(self: *@This()) Stats {
        return self.accumulated;
    }

    pub fn init() @This() {
        return .{
            .accumulated = Stats{},
        };
    }

    pub fn accumulate(self: *@This(), result: FuzzResult) void {
        const span = trace.span(.accumulate_results);
        defer span.deinit();

        self.accumulated.total_cases += 1;

        if (result.init_failed) {
            self.accumulated.init_failures += 1;
            span.debug("Test case failed during initialization", .{});
        }

        if (result.status) {
            self.accumulated.successful += 1;
        } else |err| {
            self.accumulated.errors += 1;
            self.accumulated.error_stats.recordError(err);
        }

        if (result.was_mutated) {
            self.accumulated.mutated_cases += 1;
        }

        self.accumulated.total_gas += result.gas_used;
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
        const span = trace.span(.run_fuzzer);
        defer span.deinit();
        span.debug("Starting fuzzing session with {d} test cases", .{self.config.num_cases});

        var results = FuzzResults.init();

        var test_count: u32 = self.config.start_case;
        while (test_count < self.config.num_cases) : (test_count += 1) {
            const test_case_seed = self.seed_gen
                .buildSeedFromInitialSeedAndCounter(self.config.initial_seed, test_count);
            if (self.config.verbose) {
                std.debug.print("Running test case {d}/{d} with seed {d}\r", .{ test_count + 1, self.config.num_cases, test_case_seed });
                if ((test_count + 1) % 1_000 == 0) {
                    std.debug.print("\n", .{});
                }
            }

            const result = self.runSingleTest(test_case_seed) catch |err| {
                std.debug.print("\n\x1b[31mFatal error in test case {d}/{d}\x1b[0m\n", .{
                    test_count + 1,
                    self.config.num_cases,
                });
                std.debug.print("  Seed: {d}\n", .{test_case_seed});
                std.debug.print("  Error: {s}\n", .{@errorName(err)});
                return err;
            };
            results.accumulate(result);

            // if (self.config.verbose) {
            //     self.printTestResult(test_count, result);
            // }
        }
        return results;
    }

    pub fn runSingleTest(self: *Self, seed: u64) !FuzzResult {
        const span = trace.span(.test_case);
        defer span.deinit();
        span.debug("Running test case with seed {d}", .{seed});

        var seed_gen = SeedGenerator.init(seed);

        var program_gen = try ProgramGenerator.init(self.allocator, &seed_gen);
        var memory_gen = MemoryConfigGenerator.init(self.allocator, &seed_gen);

        // Generate program
        const num_instructions = seed_gen.randomIntRange(u32, 1, self.config.max_instruction_count);
        span.debug("Generating program with {d} instructions", .{num_instructions});

        const program_span = span.child(.program_generation);
        defer program_span.deinit();

        var program = try program_gen.generate(num_instructions);
        defer program.deinit(self.allocator);

        program_span.debug("Program generated successfully", .{});
        program_span.trace("Code size: {d}, Mask size: {d}, Jump table size: {d}", .{
            program.code.len,
            program.mask.len,
            program.jump_table.len,
        });

        // Generate memory configuration
        const page_configs = try memory_gen.generatePageConfigs(program.memory_accesses);
        defer self.allocator.free(page_configs);

        // Get raw program bytes and potentially mutate them
        const mutation_span = span.child(.mutation);
        defer mutation_span.deinit();

        const program_bytes = try program.getRawBytes(self.allocator);
        const will_mutate = seed_gen.randomIntRange(u8, 0, 99) < self.config.mutation.program_mutation_probability;

        if (will_mutate) {
            mutation_span.warn("Program mutation probability check: will_mutate={}", .{will_mutate});
            // mutation_span.trace("Raw bytes before mutation: {any}", .{std.fmt.fmtSliceHexLower(program_bytes)});
            mutateProgramBytes(program_bytes, self.config.mutation, &seed_gen);
            // mutation_span.trace("Raw bytes after mutation: {any}", .{std.fmt.fmtSliceHexLower(program_bytes)});
        }

        // Initialize PVM with error handling
        const init_span = span.child(.pvm_init);
        defer init_span.deinit();
        init_span.debug("Initializing PVM with {d} bytes, {d} initial gas", .{ program_bytes.len, self.config.max_gas });

        var pvm = PVM.init(
            self.allocator,
            program_bytes,
            self.config.max_gas,
        ) catch |err| {
            init_span.err("PVM initialization failed: {s}", .{@errorName(err)});

            return FuzzResult{
                .seed = seed,
                .status = err,
                .gas_used = 0,
                .error_data = null,
                .was_mutated = will_mutate,
                .init_failed = true,
            };
        };
        defer pvm.deinit();

        // Set up memory pages
        const memory_span = span.child(.memory_setup);
        defer memory_span.deinit();
        memory_span.debug("Setting up {d} memory pages", .{page_configs.len});

        try pvm.setPageMap(page_configs);

        // Initialize memory contents
        for (page_configs, 0..) |config, i| {
            memory_span.trace("Initializing page {d}: address=0x{X:0>8}, length={d}, writable={}", .{
                i, config.address, config.length, config.is_writable,
            });

            const contents = try memory_gen.generatePageContents(config.length);
            defer self.allocator.free(contents);
            try pvm.initMemory(config.address, contents);
        }

        // Run program and collect results
        const execution_span = span.child(.execution);
        defer execution_span.deinit();

        const initial_gas = pvm.gas;
        execution_span.debug("Starting program execution with {d} gas", .{initial_gas});

        const status = pvm.run();
        const gas_used = initial_gas - pvm.gas;

        if (status) |_| {
            execution_span.debug("Program completed successfully. Gas used: {d}", .{gas_used});
        } else |err| {
            execution_span.debug("Program terminated with error: {s}. Gas used: {d}", .{ @errorName(err), gas_used });
            if (pvm.error_data) |error_data| {
                execution_span.trace("Error data: {any}", .{error_data});
            }
        }

        return FuzzResult{
            .seed = seed,
            .status = status,
            .gas_used = gas_used,
            .error_data = pvm.error_data,
            .was_mutated = will_mutate,
            .init_failed = false,
        };
    }

    fn printTestResult(_: *Self, test_number: u32, result: FuzzResult) void {
        const color = if (result.init_failed)
            "\x1b[33m" // Yellow for init failures
        else if (result.status) |_|
            "\x1b[31m" // Red for other errors
        else
            "\x1b[32m"; // Green for success

        if (result.init_failed) {
            std.debug.print("{s}Test {d}: PVM Initialization Failed, Seed={d}\x1b[0m\n", .{
                color,
                test_number + 1,
                result.seed,
            });
        } else {
            std.debug.print("{s}Test {d}: Status={any}, Gas={d}, Seed={d}\x1b[0m\n", .{
                color,
                test_number + 1,
                result.status,
                result.gas_used,
                result.seed,
            });
        }

        if (result.error_data) |error_data| {
            std.debug.print("  Error data: {any}\n", .{error_data});
        }
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

    const results = try fuzzer.run();

    const stats = results.getStats();
    std.debug.print("\nFuzzing Results:\n", .{});
    std.debug.print("Total Cases: {d}\n", .{stats.total_cases});
    std.debug.print("Successful: {d}\n", .{stats.successful});
    std.debug.print("Traps: {d}\n", .{stats.traps});
    std.debug.print("Errors: {d}\n", .{stats.errors});
    try stats.error_stats.writeErrorCounts(std.io.getStdErr().writer());
    std.debug.print("Average Gas: {d}\n", .{stats.avg_gas});
}
