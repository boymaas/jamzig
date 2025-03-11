const std = @import("std");
const pvmlib = @import("../pvm.zig");
const polkavm = @import("../pvm_test/fuzzer/polkavm_ffi.zig");

const testing = std.testing;
const InstructionWithArgs = pvmlib.PVM.InstructionWithArgs;

pub const InstructionExecutionResult = struct {
    registers: [13]u64,
    memory: ?[]const u8 = null,
    memory_address: ?u32 = null,
    status: polkavm.ExecutionStatus,
    gas_used: u64 = 0,
    final_pc: u32 = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.memory) |mem| {
            allocator.free(mem);
        }
    }
};

pub fn initPolkaVMEnvironment() !void {
    polkavm.initLogging();
}

pub const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    memory: []u8,
    memory_pages: []polkavm.MemoryPage,
    initial_registers: [13]u64,
    memory_base_address: u32 = 0x20000,
    memory_size: u32 = 0x1000,
    gas_limit: u64 = 10_000,

    pub fn init(allocator: std.mem.Allocator) !TestEnvironment {
        const memory = try allocator.alloc(u8, 0x1000);
        errdefer allocator.free(memory);

        // Clear memory
        @memset(memory, 0);

        // Create memory page
        const pages = try allocator.alloc(polkavm.MemoryPage, 1);
        errdefer allocator.free(pages);

        pages[0] = .{
            .address = 0x20000,
            .data = memory.ptr,
            .size = 0x1000,
            .is_writable = true,
        };

        // Initialize register array with zeroes
        const registers: [13]u64 = std.mem.zeroes([13]u64);

        return TestEnvironment{
            .allocator = allocator,
            .memory = memory,
            .memory_pages = pages,
            .initial_registers = registers,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.memory_pages);
        self.allocator.free(self.memory);
    }

    pub fn setRegister(self: *@This(), register_index: usize, value: u64) void {
        if (register_index < self.initial_registers.len) {
            self.initial_registers[register_index] = value;
        }
    }

    pub fn setMemory(self: *@This(), offset: usize, data: []const u8) void {
        if (offset + data.len <= self.memory.len) {
            @memcpy(self.memory[offset..][0..data.len], data);
        }
    }

    pub fn setMemoryByte(self: *@This(), offset: usize, value: u8) void {
        if (offset < self.memory.len) {
            self.memory[offset] = value;
        }
    }

    pub fn getMemory(self: *const @This()) []const u8 {
        return self.memory;
    }

    pub fn executeInstruction(self: *@This(), instruction: InstructionWithArgs) !InstructionExecutionResult {
        const encoded_instruction = try instruction.encodeOwned();

        // Create bitmask (the simplest one - just a single instruction)
        const bitmask = [_]u8{0b00000001};

        // Create jump table (simplest possible)
        const jump_table = [_]u32{1};

        // Build the program
        const raw_program = try polkavm.ProgramBuilder.init(
            self.allocator,
            encoded_instruction.asSlice(),
            &bitmask,
            &jump_table,
            &[_]u8{}, // ro_data
            &[_]u8{}, // rw_data
            .{}, // default config
        ).build();
        defer self.allocator.free(raw_program);

        // Initialize executor with our memory and registers
        var executor = try polkavm.Executor.init(raw_program, self.memory_pages, &self.initial_registers, self.gas_limit);
        defer executor.deinit();

        // Execute a single step, this is the first jump
        {
            const execution_result = executor.step();
            defer execution_result.deinit();
        }

        // Now execute the actual instruction
        const execution_result = executor.step();
        defer execution_result.deinit();

        // Capture memory changes if applicable
        var result_memory: ?[]const u8 = null;
        var memory_address: ?u32 = null;

        // For instruction that access memory, we need to capture the changes
        if (instruction.getMemoryAccess()) |access| {
            // Calculate the offset in our memory array
            const page_offset = access.address - self.memory_base_address;

            // Only capture memory if it's a write operation
            if (access.isWrite and page_offset < self.memory_size) {
                const capture_start = page_offset;
                const capture_size = @min(access.size, self.memory_size - capture_start);

                // Make a copy of the affected memory region
                result_memory = try self.allocator.dupe(u8, execution_result.raw.pages.?[0].data[capture_start..][0..capture_size]);
                memory_address = @intCast(access.address);
            }
        }

        return InstructionExecutionResult{
            .registers = execution_result.raw.registers,
            .memory = result_memory,
            .memory_address = memory_address,
            .status = execution_result.raw.status,
            .gas_used = self.gas_limit - @as(u64, @intCast(execution_result.raw.gas_remaining)),
            .final_pc = execution_result.raw.final_pc,
        };
    }
};

test "pvm:fuzz:execute_instruction" {
    try initPolkaVMEnvironment();

    var env = try TestEnvironment.init(testing.allocator);
    defer env.deinit();

    // Set up register r1 with an initial value
    env.setRegister(1, 1000);

    // Create a simple add_imm_64 instruction that adds 42 to register r1
    const instruction = InstructionWithArgs{ .instruction = .add_imm_64, .args = .{
        .TwoRegOneImm = .{
            .first_register_index = 1,
            .second_register_index = 1,
            .immediate = 42,
            .no_of_bytes_to_skip = 3,
        },
    } };

    // Execute the instruction
    var result = try env.executeInstruction(instruction);
    defer result.deinit(testing.allocator);

    // Verify the execution was successful
    try testing.expectEqual(polkavm.ExecutionStatus.Running, result.status);

    // Verify register r1 now contains 1000 + 42 = 1042
    try testing.expectEqual(@as(u64, 1042), result.registers[1]);
}

test "pvm:fuzz:memory_operations" {
    try initPolkaVMEnvironment();

    var env = try TestEnvironment.init(testing.allocator);
    defer env.deinit();

    // Set up test value in register
    const test_value: u64 = 0x1122334455667788;
    env.setRegister(1, test_value);

    // Calculate memory offset relative to page base
    const mem_offset: u32 = 0x100;
    const mem_addr = env.memory_base_address + mem_offset;

    // Create a store_u64 instruction to write register r1 to memory
    const store_instruction = InstructionWithArgs{ .instruction = .store_u64, .args = .{
        .OneRegOneImm = .{
            .register_index = 1,
            .immediate = mem_addr,
            .no_of_bytes_to_skip = 7,
        },
    } };

    // Execute the store
    var store_result = try env.executeInstruction(store_instruction);
    defer store_result.deinit(testing.allocator);

    std.debug.print("{any}\n", .{store_result});

    // print the full memory region here
    std.debug.print("{}\n", .{std.fmt.fmtSliceHexLower(store_result.memory.?)});

    // read the value written to memory
    const written_value = std.mem.readInt(u64, store_result.memory.?[0..8], .little);
    try std.testing.expectEqual(test_value, written_value);

    // Now create a new environment for the load operation
    var env2 = try TestEnvironment.init(testing.allocator);
    defer env2.deinit();

    // Copy the same memory content
    var expected_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected_bytes, test_value, .little);
    @memcpy(env2.memory[mem_offset..][0..8], &expected_bytes);

    // Create a load_u64 instruction to read from memory into register r2
    const load_instruction = InstructionWithArgs{ .instruction = .load_u64, .args = .{
        .OneRegOneImm = .{
            .register_index = 2,
            .immediate = mem_addr,
            .no_of_bytes_to_skip = 7,
        },
    } };

    // Execute the load
    var load_result = try env2.executeInstruction(load_instruction);
    defer load_result.deinit(testing.allocator);

    // Verify register r2 contains the value we previously stored
    try testing.expectEqual(test_value, load_result.registers[2]);
}

test "pvm:fuzz:instructions" {
    const allocator = std.testing.allocator;

    try initPolkaVMEnvironment();

    // Create test environment
    var env = try TestEnvironment.init(allocator);
    defer env.deinit();

    // Set up register r1 with a test value
    env.setRegister(1, 4278059008);

    // Create an add_imm_64 instruction that tests negative immediate
    const instruction = InstructionWithArgs{ .instruction = .add_imm_64, .args = .{
        .TwoRegOneImm = .{
            .first_register_index = 1,
            .second_register_index = 1,
            .immediate = 0xfffffffffffff808,
            .no_of_bytes_to_skip = 3,
        },
    } };

    // Log instruction details
    std.debug.print("Instruction: {s}, first_reg: {}, second_reg: {}, immediate: 0x{x}\n", .{
        @tagName(instruction.instruction),
        instruction.args.TwoRegOneImm.first_register_index,
        instruction.args.TwoRegOneImm.second_register_index,
        instruction.args.TwoRegOneImm.immediate,
    });

    // Execute the instruction
    var result = try env.executeInstruction(instruction);
    defer result.deinit(allocator);

    // Print final register value
    std.debug.print("Final register r1 value: {d}\n", .{result.registers[1]});
}
