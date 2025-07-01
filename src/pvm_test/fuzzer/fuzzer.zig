const std = @import("std");
const Allocator = std.mem.Allocator;
const PVM = @import("../../pvm.zig").PVM;
const SeedGenerator = @import("seed.zig").SeedGenerator;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const Register = @import("../../pvm/registers.zig").Register;

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
    max_gas: u32 = 100,
    /// Maximum number of basic blocks per program
    max_instruction_count: u32 = 32,
    /// Whether to print verbose output
    verbose: bool = false,
    /// Configuration for program mutations
    mutation: MutationConfig = .{},
    /// Enable cross-checking against reference implementation
    enable_cross_check: bool = false,
};

pub const FuzzResult = struct {
    seed: u64,
    status: PVM.Error!PVM.SingleStepResult,
    gas_used: i64,
    was_mutated: bool,
    // error_data: ?PVM.ErrorData,
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

    const ExecutionStats = struct {
        halt: usize = 0,
        panic: usize = 0,
        out_of_gas: usize = 0,
        page_fault: usize = 0,
        host_call: usize = 0,
    };

    const Stats = struct {
        total_cases: usize = 0,
        successful: usize = 0,
        errors: usize = 0,
        total_gas: i64 = 0,
        mutated_cases: usize = 0,
        init_failures: usize = 0,
        error_stats: ErrorStats = ErrorStats.init(),
        error_stats_mutated: ErrorStats = ErrorStats.init(),
        execution_stats: ExecutionStats = .{},

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

        if (result.status) |status| {
            switch (status) {
                .terminal => |err| switch (err) {
                    .halt => |_| {
                        self.accumulated.successful += 1;
                        self.accumulated.execution_stats.halt += 1;
                    },
                    .panic => self.accumulated.execution_stats.panic += 1,
                    .out_of_gas => self.accumulated.execution_stats.out_of_gas += 1,
                    .page_fault => self.accumulated.execution_stats.page_fault += 1,
                },
                .host_call => self.accumulated.execution_stats.host_call += 1,
                else => {},
            }
        } else |err| {
            if (result.was_mutated) {
                self.accumulated.error_stats_mutated.recordError(err);
            } else {
                self.accumulated.errors += 1;
                self.accumulated.error_stats.recordError(err);
            }
        }

        if (result.was_mutated) {
            self.accumulated.mutated_cases += 1;
        }

        self.accumulated.total_gas += result.gas_used;
    }

    pub fn writeExecutionStats(self: *const @This(), writer: anytype) !void {
        try writer.writeAll("\nExecution Result Statistics:\n");
        try writer.print("    Halt: {d}\n", .{self.accumulated.execution_stats.halt});
        try writer.print("    Panic: {d}\n", .{self.accumulated.execution_stats.panic});
        try writer.print("    Out of Gas: {d}\n", .{self.accumulated.execution_stats.out_of_gas});
        try writer.print("    Page Fault: {d}\n", .{self.accumulated.execution_stats.page_fault});
        try writer.print("    Host Call: {d}\n", .{self.accumulated.execution_stats.host_call});
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

    pub fn run(self: *Self) !struct { results: FuzzResults, init_errors: FuzzResults } {
        const span = trace.span(.run_fuzzer);
        defer span.deinit();
        span.debug("Starting fuzzing session with {d} test cases", .{self.config.num_cases});

        var init_errors = FuzzResults.init();
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
            if (result.init_failed) {
                init_errors.accumulate(result);
            } else {
                results.accumulate(result);
            }
        }
        return .{ .results = results, .init_errors = init_errors };
    }

    pub fn runSingleTest(self: *Self, seed: u64) !FuzzResult {
        const span = trace.span(.test_case);
        defer span.deinit();
        span.debug("Running test case with seed {d}", .{seed});

        var seed_gen = SeedGenerator.init(seed);
        var program_gen = try ProgramGenerator.init(self.allocator, &seed_gen);

        // Generate program
        const num_instructions = seed_gen.randomIntRange(u32, 1, self.config.max_instruction_count);
        span.debug("Generating program with {d} instructions", .{num_instructions});

        var program = try program_gen.generate(num_instructions);
        defer program.deinit(self.allocator);

        // Rewrite memory accesses
        try program.rewriteMemoryAccesses(
            &seed_gen,
            try PVM.Memory.HEAP_BASE_ADDRESS(0),
            PVM.Memory.Z_P * 4,
        );

        const program_bytes = try program.getRawBytes(self.allocator);
        const will_mutate = seed_gen.randomIntRange(u16, 0, 999) < self.config.mutation.program_mutation_probability;

        if (will_mutate) mutate: {
            // We do not want crazy stuff when we are cross checking
            if (self.config.enable_cross_check) {
                span.warn("Skipping program mutation during cross-check validation", .{});
                break :mutate;
            }

            span.warn("Mutating program", .{});
            mutateProgramBytes(program_bytes, self.config.mutation, &seed_gen);
        }

        // Initialize our PVM
        var exec_ctx = PVM.ExecutionContext.initSimple(
            self.allocator,
            program_bytes,
            1024, // Stack size
            4, // Heap size
            self.config.max_gas,
            false,
        ) catch |err| {
            span.err("ExecutionContext initialization failed: {s}", .{@errorName(err)});
            return FuzzResult{
                .seed = seed,
                .status = err,
                .gas_used = 0,
                .was_mutated = will_mutate,
                .init_failed = true,
            };
        };
        defer exec_ctx.deinit(self.allocator);

        // Register host call handler
        var host_calls_map = std.AutoHashMapUnmanaged(u32, PVM.HostCallFn){};
        defer host_calls_map.deinit(self.allocator);
        try host_calls_map.put(self.allocator, 0, struct {
            pub fn func(ctx: *PVM.ExecutionContext, _: *anyopaque) PVM.HostCallResult {
                _ = ctx;
                return .play;
            }
        }.func);
        exec_ctx.setHostCalls(&host_calls_map);

        // Limit PVM allocations
        exec_ctx.memory.heap_allocation_limit = 8;

        // Initialize registers
        seed_gen.randomBytes(std.mem.asBytes(&exec_ctx.registers));
        const initial_registers = exec_ctx.registers;

        // Optional FFI executor for cross-checking
        var ref_executor: ?polkavm_ffi.Executor = null;
        defer if (ref_executor) |*executor| executor.deinit();

        // Initialize FFI executor if cross-checking is enabled
        if (self.config.enable_cross_check) cross_check_init: {
            // Check for sbrk instruction
            var inst_iter = exec_ctx.decoder.iterator();
            while (try inst_iter.next()) |e| {
                if (e.inst.instruction == .sbrk) {
                    span.debug("skipping cross-check for code with unimplemented sbrk", .{});
                    break :cross_check_init;
                }
            }

            // Check if pvm scope tracing is enabled, in that case we want polkavm logging as well
            // NOTE: use RUST_LOG=trace to actually show the pvm logs
            if (@import("../../tracing.zig").findScope("pvm")) |_| {
                polkavm_ffi.initLogging();
            }

            // Setup memory pages for FFI
            var pages = try std.ArrayList(polkavm_ffi.MemoryPage).initCapacity(
                self.allocator,
                exec_ctx.memory.page_table.pages.items.len,
            );
            defer pages.deinit();

            // Create pages matching our PVM layout
            for (exec_ctx.memory.page_table.pages.items) |page| {
                const page_data = try self.allocator.alloc(u8, page.data.len);
                errdefer self.allocator.free(page_data);
                @memset(page_data, 0);

                try pages.append(.{
                    .address = page.address,
                    .data = page_data.ptr,
                    .size = page.data.len,
                    .is_writable = page.flags == .ReadWrite,
                });
            }

            // Initialize FFI executor
            ref_executor = try polkavm_ffi.createExecutorFromProgram(
                self.allocator,
                program,
                pages.items,
                &initial_registers,
                std.math.maxInt(i64), // @intCast(self.config.max_gas),
            );

            // Free temporary page data
            for (pages.items) |page| {
                self.allocator.free(page.data[0..page.size]);
            }
        }

        // We need to do one step to "initialze" the polkavm
        if (ref_executor) |*executor| {
            const _r = executor.step();
            defer _r.deinit();
        }

        // Main execution loop
        const initial_gas = exec_ctx.gas;
        // FIXME: for now gas is 0 so we need to limit with max_iteration when gas is introduced again we can remove
        var max_iterations = initial_gas;
        while (true) : (max_iterations -= 1) {
            if (max_iterations == 0) {
                return FuzzResult{
                    .seed = seed,
                    .status = .{ .terminal = .out_of_gas },
                    .gas_used = initial_gas -| exec_ctx.gas,
                    .was_mutated = will_mutate,
                    .init_failed = false,
                };
            }
            // Execute one step in our PVM
            const current_pc = exec_ctx.pc;
            const current_instruction = try exec_ctx.decoder.decodeInstruction(current_pc);

            // NOTE: that when .sbrk is present we do not do do a crosscheck
            // which is why the crosscheck will not fail as we do not skip
            // the instruction there
            if (current_instruction.instruction == .sbrk) {
                span.warn("Skipping sbrk instruction for now", .{});
                exec_ctx.pc += 1 + current_instruction.skip_l();
                continue;
            }

            const step_result = PVM.singleStepInvocation(&exec_ctx) catch |err| {
                std.debug.print("\nPVM errored during execution: {s}\n", .{@errorName(err)});
                return error.PvmErroredInNormalOperation;
            };

            // If cross-checking is enabled and we have a reference executor
            if (ref_executor) |*executor| cross_check: {
                // If our PVM has a term result, we do not cross check
                if (step_result.isTerminal()) {
                    break :cross_check;
                }

                // Execute one step in reference implementation
                const ref_result = executor.step();
                defer ref_result.deinit();

                // we need to inject another step if we run into a hostcall
                if (current_instruction.instruction == .ecalli) {
                    const _r = executor.step();
                    defer _r.deinit();
                }

                // Compare states
                try compareRegisters("Step", exec_ctx.registers[0..13], ref_result.getRegisters()[0..13]);
                try compareMemoryPages(&exec_ctx.memory, ref_result.getPages());

                // Compare execution status
                const expected_status = pvmStepToFfiStatus(step_result);
                if (ref_result.raw.status != expected_status) check_status: {
                    if (ref_result.raw.status == .OutOfGas) {
                        // Gas accounting is different on polkavm ignoring this for now
                        break :check_status;
                    }
                    std.debug.print("\nStatus mismatch during step-by-step execution!\n", .{});
                    std.debug.print("  Our implementation: {any}\n", .{step_result});
                    std.debug.print("  Reference impl: {any}\n", .{ref_result.raw.status});
                    return error.CrossCheckStatusMismatch;
                }
            }

            // Process step result
            switch (step_result) {
                .cont => continue,
                .host_call => |host| {
                    const handler = exec_ctx.host_calls.?.get(host.idx) orelse
                        return FuzzResult{
                        .seed = seed,
                        .status = .{ .terminal = .panic },
                        .gas_used = initial_gas - exec_ctx.gas,
                        .was_mutated = will_mutate,
                        .init_failed = false,
                    };

                    // Execute host call
                    const dummy_ctx = struct {};
                    const result = handler(&exec_ctx, @ptrCast(@constCast(&dummy_ctx)));
                    switch (result) {
                        .play => {
                            exec_ctx.pc = host.next_pc;
                            continue;
                        },
                        .terminal => |term| switch (term) {
                            .page_fault => |addr| {
                                return FuzzResult{
                                    .seed = seed,
                                    .status = .{ .terminal = .{ .page_fault = addr } },
                                    .gas_used = initial_gas - exec_ctx.gas,
                                    .was_mutated = will_mutate,
                                    .init_failed = false,
                                };
                            },
                            else => {
                                // FIXME: we can track more errors on hostcalls

                            },
                        },
                    }
                },
                .terminal => |result| {
                    return FuzzResult{
                        .seed = seed,
                        .status = switch (result) {
                            .halt => .{ .terminal = .halt },
                            .panic => .{ .terminal = .panic },
                            .out_of_gas => .{ .terminal = .out_of_gas },
                            .page_fault => |addr| .{ .terminal = .{ .page_fault = addr } },
                        },
                        .gas_used = initial_gas - exec_ctx.gas,
                        .was_mutated = will_mutate,
                        .init_failed = false,
                    };
                },
            }
        }
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
    try results.writeExecutionStats(std.io.getStdErr().writer());
    std.debug.print("Average Gas: {d}\n", .{stats.avg_gas});
}

// Crosscheck
const polkavm_ffi = @import("polkavm_ffi.zig");

pub const CrossCheckError = error{
    CrossCheckStatusMismatch,
    CrossCheckMemoryMismatch,
    CrossCheckRegisterMismatch,
    CrossCheckGasMismatch,
    CrossCheckPCMismatch,
    PvmErroredInNormalOperation,
};

// Helper function to convert PVM step result to FFI status
fn pvmStepToFfiStatus(step: PVM.SingleStepResult) polkavm_ffi.ExecutionStatus {
    return switch (step) {
        .cont => .Running,
        .host_call => .Running, // Host calls should be played in PVM first
        .terminal => |t| switch (t) {
            .halt => .Success,
            .panic => .Trap,
            .out_of_gas => .OutOfGas,
            .page_fault => .Segfault,
        },
    };
}

pub fn compareRegisters(msg: []const u8, our_registers: []const u64, ref_registers: []const u64) !void {
    for (ref_registers, 0..) |ref_reg, i| {
        if (ref_reg != our_registers[i]) {
            std.debug.print("\n{s} register state mismatch detected!\n", .{msg});
            std.debug.print("Register {d}:\n", .{i});
            std.debug.print("  Our implementation: 0x{X:0>16}\n", .{our_registers[i]});
            std.debug.print("  Reference impl:     0x{X:0>16}\n", .{ref_reg});
            return error.CrossCheckRegisterMismatch;
        }
    }
}

pub fn compareMemoryPages(memory: *PVM.Memory, ref_pages: []const polkavm_ffi.MemoryPage) !void {
    for (ref_pages) |ref_page| {
        // Get our corresponding page
        if (memory.page_table.findPageOfAddresss(ref_page.address)) |our_page| {
            // Compare page contents
            const ref_data = ref_page.data[0..ref_page.size];
            const our_data = our_page.page.data[0..ref_page.size];

            if (!std.mem.eql(u8, ref_data, our_data)) {
                std.debug.print("\nMemory state mismatch detected!\n", .{});
                std.debug.print("Page address: 0x{X:0>8}\n", .{ref_page.address});
                std.debug.print("First differing byte at offset: {d}\n", .{
                    std.mem.indexOfDiff(u8, ref_data, our_data).?,
                });
                return error.CrossCheckMemoryMismatch;
            }
        } else {
            std.debug.print("\nMissing memory page in our implementation!\n", .{});
            std.debug.print("Page address: 0x{X:0>8}\n", .{ref_page.address});
            return error.CrossCheckMemoryMismatch;
        }
    }
}
