const std = @import("std");
const pvmlib = @import("../pvm.zig");
const PVM = pvmlib.PVM;
const Memory = PVM.Memory;
const ExecutionContext = PVM.ExecutionContext;
const InstructionWithArgs = PVM.InstructionWithArgs;

const codec = @import("../codec.zig");

const trace = @import("../tracing.zig").scoped(.pvm_test);

pub const InstructionExecutionResult = struct {
    registers: [13]u64,
    memory: ?[]const u8 = null,
    memory_address: ?u32 = null,
    // In PVM we have more detailed status than polkavm
    status: union(enum) {
        success,
        terminal: PVM.InvocationException,
        @"error": PVM.Error,
    },
    gas_used: u64 = 0,
    final_pc: u32 = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.memory) |mem| {
            allocator.free(mem);
        }
    }
};

/// Test environment for PVM instruction execution
pub const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    initial_registers: [13]u64,

    initial_memory: PVM.Memory,
    memory_base_address: u32 = 0x20000,
    memory_size: u32 = 0x1000,
    gas_limit: u32 = 10_000,

    pub fn init(allocator: std.mem.Allocator) !TestEnvironment {
        // Configure memory
        var memory = try Memory.initEmpty(allocator, false);
        errdefer memory.deinit();

        // Allocate a single page at the specified address
        try memory.allocatePageAt(0x20000, .ReadWrite);

        // All zereos
        const registers: [13]u64 = std.mem.zeroes([13]u64);

        return TestEnvironment{
            .allocator = allocator,
            .initial_registers = registers,
            .initial_memory = memory,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.initial_memory.deinit();
    }

    pub fn setRegister(self: *@This(), register_index: usize, value: u64) void {
        if (register_index < self.initial_registers.len) {
            self.initial_registers[register_index] = value;
        }
    }

    pub fn setMemory(self: *@This(), offset: usize, data: []const u8) !void {
        if (offset + data.len <= self.memory_size) {
            try self.initial_memory.writeSlice(self.memory_base_address + @as(u32, @intCast(offset)), data);
        }
    }

    pub fn setMemoryByte(self: *@This(), offset: usize, value: u8) !void {
        if (offset < self.memory_size) {
            try self.initial_memory.writeU8(self.memory_base_address + @as(u32, @intCast(offset)), value);
        }
    }

    pub fn getMemory(self: *const @This(), offset: usize, length: usize) !Memory.MemorySlice {
        if (offset + length <= self.memory_size) {
            return try self.initial_memory.readSlice(
                self.memory_base_address + @as(u32, @intCast(offset)),
                length,
            );
        }
        return error.OutOfBounds;
    }

    pub fn executeInstruction(self: *@This(), instruction: InstructionWithArgs) !InstructionExecutionResult {
        // Encode the instruction into the program's code section
        const encoded = try instruction.encodeOwned();

        // Use ArrayList to build the program
        var program_buffer = std.ArrayList(u8).init(self.allocator);
        defer program_buffer.deinit();

        // Create a writer for the ArrayList
        const writer = program_buffer.writer();

        // Write program header
        try writer.writeByte(0);
        try writer.writeByte(0);
        try codec.writeInteger(encoded.len, writer);

        // Write encoded instruction
        try writer.writeAll(encoded.asSlice());

        // Write program mask
        const mask_bytes = try std.math.divCeil(usize, encoded.len, 8);
        try writer.writeByte(0x01);
        if (mask_bytes > 1) {
            try writer.writeByte(0x00);
        }

        // Get the final program
        const raw_program = try program_buffer.toOwnedSlice();
        defer self.allocator.free(raw_program);

        var execution_context = try ExecutionContext.initSimple(
            self.allocator,
            raw_program,
            0x100,
            0,
            self.gas_limit,
            false,
        );
        defer execution_context.deinit(self.allocator);

        // Configure memory
        execution_context.memory.deinit();
        execution_context.memory = try self.initial_memory.deepClone(self.allocator);

        // Reset PC
        execution_context.pc = 0;
        execution_context.registers = self.initial_registers;

        // Get memory access information if this instruction touches memory
        const memory_access = instruction.getMemoryAccess();

        // Execute a single step
        const result = PVM.singleStepInvocation(&execution_context) catch |err| {
            return InstructionExecutionResult{
                .registers = execution_context.registers,
                .status = .{ .@"error" = err },
                .gas_used = @intCast(@as(i64, self.gas_limit) - execution_context.gas),
                .final_pc = execution_context.pc,
            };
        };

        // Capture memory changes if applicable
        var result_memory: ?[]const u8 = null;
        var memory_address: ?u32 = null;

        if (memory_access) |access| {
            // Only capture memory if it's a write operation
            if (access.isWrite) {
                // Calculate offset from memory base address
                var capture_address = access.address;

                // If this was indirect access we have a different capture address
                if (access.isIndirect) {
                    const ind_memory_access = try instruction.getMemoryAccessInd(&execution_context.registers);
                    capture_address = ind_memory_access.address;
                }

                // Make a copy of the affected memory region
                const mem_data = execution_context.memory.readSliceOwned(
                    @intCast(capture_address),
                    access.size,
                ) catch {
                    // If we can't read the memory, just return null
                    return InstructionExecutionResult{
                        .registers = execution_context.registers,
                        .status = switch (result) {
                            .cont => .success,
                            .host_call => .success, // Simplified - we don't handle host calls in this test
                            .terminal => |term| .{ .terminal = term },
                        },
                        .gas_used = @intCast(@as(i64, self.gas_limit) - execution_context.gas),
                        .final_pc = execution_context.pc,
                    };
                };

                result_memory = mem_data;
                memory_address = @intCast(capture_address);
            }
        }

        return InstructionExecutionResult{
            .registers = execution_context.registers,
            .memory = result_memory,
            .memory_address = memory_address,
            .status = switch (result) {
                .cont => .success,
                .host_call => .success, // Simplified - we don't handle host calls in this test
                .terminal => |term| .{ .terminal = term },
            },
            .gas_used = @intCast(@as(i64, self.gas_limit) - execution_context.gas),
            .final_pc = execution_context.pc,
        };
    }
};

test "pvm:fuzz:execute_instruction" {
    const testing = std.testing;

    var env = try TestEnvironment.init(testing.allocator);
    defer env.deinit();

    // Set up register r1 with an initial value
    env.setRegister(1, 4278059008);

    // Create a simple add_imm_64 instruction that adds 42 to register r1
    const instruction = InstructionWithArgs{ .instruction = .add_imm_64, .args = .{
        .TwoRegOneImm = .{
            .first_register_index = 1,
            .second_register_index = 1,
            .immediate = 0xfffffffffffff808,
            .no_of_bytes_to_skip = 3,
        },
    } };

    // Execute the instruction
    var result = try env.executeInstruction(instruction);
    defer result.deinit(testing.allocator);

    // Verify the execution was successful
    try testing.expectEqual(true, result.status == .success);

    // Verify register r1 now contains 1000 + 42 = 1042
    try testing.expectEqual(@as(u64, 4278056968), result.registers[1]);
}

test "pvm:fuzz:memory_operations" {
    const testing = std.testing;

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

    // Verify the memory was written to
    try testing.expect(store_result.memory != null);
    try testing.expect(store_result.memory_address != null);

    if (store_result.memory) |mem| {
        // Verify the value written to memory matches what we expect
        const written_value = std.mem.readInt(u64, mem[0..8], .little);
        try testing.expectEqual(test_value, written_value);
    }

    // Now test reading from memory
    // First, explicitly set memory to a known value
    env.setRegister(1, 0);
    try env.setMemory(mem_offset, &[_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 });

    // Create a load_u64 instruction to read from memory into register r2
    const load_instruction = InstructionWithArgs{ .instruction = .load_u64, .args = .{
        .OneRegOneImm = .{
            .register_index = 2,
            .immediate = mem_addr,
            .no_of_bytes_to_skip = 7,
        },
    } };

    // Execute the load
    var load_result = try env.executeInstruction(load_instruction);
    defer load_result.deinit(testing.allocator);

    // Verify register r2 contains the value we previously stored
    try testing.expectEqual(test_value, load_result.registers[2]);
}
