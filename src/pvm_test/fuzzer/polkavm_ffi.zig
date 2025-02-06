const std = @import("std");

const GeneratedProgram = @import("program_generator.zig").GeneratedProgram;
const ProgramGenerator = @import("program_generator.zig").ProgramGenerator;
const ProgramBuilder = @import("polkavm_ffi/program_builder.zig").ProgramBuilder;
const SeedGenerator = @import("seed.zig").SeedGenerator;

pub const MemoryPage = extern struct {
    address: u32,
    data: [*]u8,
    size: usize,
    is_writable: bool,

    pub fn empty(allocator: std.mem.Allocator) ![]MemoryPage {
        return try allocator.alloc(MemoryPage, 0);
    }
};

pub const ExecutionStatus = enum(c_int) {
    Success = 0,
    Trap = 1,
    OutOfGas = 2,
    Segfault = 3,
    InstanceRunError = 4,
    Running = 5,
};

const RawExecutionResult = extern struct {
    status: ExecutionStatus,
    final_pc: u32,
    pages: ?[*]MemoryPage,
    page_count: usize,
    registers: [13]u64,
    gas_remaining: i64,
    segfault_address: u32,
};

pub const ExecutionResult = struct {
    raw: RawExecutionResult,

    pub fn deinit(self: *const ExecutionResult) void {
        free_execution_result(self.raw);
    }

    pub fn getPages(self: *const ExecutionResult) []const MemoryPage {
        return self.raw.pages.?[0..self.raw.page_count];
    }

    pub fn getRegisters(self: *const ExecutionResult) []const u64 {
        return &self.raw.registers;
    }

    pub fn isFinished(self: *const ExecutionResult) bool {
        return switch (self.raw.status) {
            .Success, .Trap, .OutOfGas, .Segfault, .InstanceRunError => true,
            .Running => false,
        };
    }
};

// Opaque type for the executor
const ProgramExecutor = opaque {};

extern "c" fn init_logging() void;
extern "c" fn free_execution_result(result: RawExecutionResult) void;

extern "c" fn create_executor(
    bytecode: [*]const u8,
    bytecode_len: usize,
    initial_pages: [*]const MemoryPage,
    page_count: usize,
    initial_registers: [*]const u64,
    gas_limit: u64,
) ?*ProgramExecutor;

extern "c" fn step_executor(
    executor: *ProgramExecutor,
) RawExecutionResult;

extern "c" fn is_executor_finished(
    executor: *const ProgramExecutor,
) bool;

extern "c" fn free_executor(
    executor: *ProgramExecutor,
) void;

pub fn initLogging() void {
    init_logging();
}

/// Wrapper for the ProgramExecutor that provides a more Zig-friendly interface
pub const Executor = struct {
    executor: *ProgramExecutor,

    const Self = @This();

    pub const Error = error{
        ExecutorCreationFailed,
        ExecutionError,
    };

    pub fn init(
        bytecode: []const u8,
        pages: []const MemoryPage,
        registers: []const u64,
        gas_limit: u64,
    ) Error!Self {
        const executor = create_executor(
            bytecode.ptr,
            bytecode.len,
            pages.ptr,
            pages.len,
            registers.ptr,
            gas_limit,
        ) orelse return error.ExecutorCreationFailed;

        return Self{
            .executor = executor,
        };
    }

    pub fn deinit(self: *Self) void {
        free_executor(self.executor);
    }

    pub fn step(self: *Self) ExecutionResult {
        return .{
            .raw = step_executor(self.executor),
        };
    }

    pub fn isFinished(self: *const Self) bool {
        return is_executor_finished(self.executor);
    }

    pub fn runToCompletion(self: *Self) Error!ExecutionResult {
        var last_result: ExecutionResult = undefined;
        while (!self.isFinished()) {
            last_result = self.step();
        }
        return last_result;
    }
};

/// Convenience function to build program bytes from a GeneratedProgram
pub fn buildProgramBytes(
    allocator: std.mem.Allocator,
    program: GeneratedProgram,
) ![]u8 {
    var builder = ProgramBuilder.init(
        allocator,
        program.code,
        program.mask,
        program.jump_table,
        &.{}, // ro_data
        &.{}, // rw_data
        .{}, // default config
    );

    return builder.build();
}

/// Creates an executor from a GeneratedProgram
pub fn createExecutorFromProgram(
    allocator: std.mem.Allocator,
    program: GeneratedProgram,
    pages: []const MemoryPage,
    registers: []const u64,
    gas_limit: u64,
) !Executor {
    const program_bytes = try buildProgramBytes(allocator, program);
    defer allocator.free(program_bytes);

    return Executor.init(program_bytes, pages, registers, gas_limit);
}

test "stepped execution" {
    const allocator = std.testing.allocator;

    // Setup memory page
    const memory = try allocator.alloc(u8, 0x1000);
    defer allocator.free(memory);

    const page = MemoryPage{
        .address = 0x20000,
        .data = memory.ptr,
        .size = 0x1000,
        .is_writable = true,
    };

    // Initialize generator
    var seed_gen = SeedGenerator.init(42);
    var generator = try ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    // Test different program sizes
    const sizes = [_]u32{ 16, 32 };

    for (0..10) |_| {
        for (sizes) |size| {
            // Generate program
            var program = try generator.generate(size);
            defer program.deinit(allocator);

            // Initial registers
            var registers: [13]u64 = undefined;
            seed_gen.randomBytes(std.mem.asBytes(&registers));

            // Create executor
            {
                var executor = try createExecutorFromProgram(
                    allocator,
                    program,
                    &[_]MemoryPage{page},
                    &registers,
                    10000,
                );
                defer executor.deinit();

                // Test step-by-step execution
                var step_count: usize = 0;
                while (!executor.isFinished()) {
                    const result = executor.step();
                    defer result.deinit();
                    // try std.testing.expect(result.raw.status != .Running);
                    step_count += 1;
                }

                // Verify we took some steps
                try std.testing.expect(step_count > 0);
            }

            // Test run to completion
            {
                var executor = try createExecutorFromProgram(
                    allocator,
                    program,
                    &[_]MemoryPage{page},
                    &registers,
                    10000,
                );
                defer executor.deinit();

                const result = try executor.runToCompletion();
                defer result.deinit();

                try std.testing.expect(result.isFinished());
            }
        }
    }
}
