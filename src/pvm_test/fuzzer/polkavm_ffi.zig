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
};

pub const ExecutionStatus = enum(c_int) {
    Success = 0,
    EngineError = 1,
    ProgramError = 2,
    ModuleError = 3,
    InstantiationError = 4,
    MemoryError = 5,
    Trap = 6,
    OutOfGas = 7,
    Segfault = 8,
    InstanceRunError = 9,
    UnknownError = 10,
};

const RawExecutionResult = extern struct {
    status: ExecutionStatus,
    final_pc: u32,
    pages: ?[*]MemoryPage,
    page_count: usize,
};

pub const ExecutionResult = struct {
    raw: RawExecutionResult,

    pub fn deinit(self: *const ExecutionResult) void {
        free_execution_result(self.raw);
    }

    pub fn getPages(self: *const ExecutionResult) []const MemoryPage {
        return self.raw.pages[0..self.raw.page_count];
    }
};

extern "c" fn execute_pvm(
    bytecode: [*]const u8,
    bytecode_len: usize,
    initial_pages: [*]const MemoryPage,
    page_count: usize,
    gas_limit: u64,
) RawExecutionResult;

extern "c" fn free_execution_result(result: RawExecutionResult) void;

/// Wrapper for execute_pvm that provides a more Zig-friendly interface
pub fn executePvm(
    bytecode: []const u8,
    pages: []const MemoryPage,
    gas_limit: u64,
) ExecutionResult {
    return .{
        .raw = execute_pvm(
            bytecode.ptr,
            bytecode.len,
            pages.ptr,
            pages.len,
            gas_limit,
        ),
    };
}

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

/// Wrapper takes a GeneratedProgram converts it and executes it
pub fn executePvmWithGeneratedProgram(
    allocator: std.mem.Allocator,
    program: GeneratedProgram,
    pages: []const MemoryPage,
    gas_limit: u64,
) !ExecutionResult {
    const program_bytes = try buildProgramBytes(allocator, program);
    defer allocator.free(program_bytes);

    return executePvm(program_bytes, pages, gas_limit);
}

test "generate and execute multiple programs" {
    const allocator = std.testing.allocator;

    // Setup memory page for program execution
    const memory = try allocator.alloc(u8, 0x1000);
    defer allocator.free(memory);

    const page = MemoryPage{
        .address = 0x20000,
        .data = memory.ptr,
        .size = 0x1000,
        .is_writable = true,
    };

    // Initialize program generator
    var seed_gen = SeedGenerator.init(42);
    var generator = try ProgramGenerator.init(allocator, &seed_gen);
    defer generator.deinit();

    // Test different program sizes
    const sizes = [_]u32{ 16, 32, 64, 128 };

    for (0..10_000) |_| {
        for (sizes) |size| {
            // Generate program
            var program = try generator.generate(size);
            defer program.deinit(allocator);

            // Execute program
            const result = try executePvmWithGeneratedProgram(
                allocator,
                program,
                &[_]MemoryPage{page},
                10000, // gas limit
            );
            defer result.deinit();

            // std.debug.print("{}\n", result);

            // Verify execution completed
            try std.testing.expect(result.raw.status != .UnknownError);
            // try std.testing.expect(result.raw.page_count > 0);

            // Verify memory pages are accessible
            // const pages = result.getPages();
            // try std.testing.expect(pages.len > 0);
            // try std.testing.expectEqual(pages[0].size, 0x1000);
        }
    }
}
