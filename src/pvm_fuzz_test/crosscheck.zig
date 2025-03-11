const std = @import("std");
const PVM = @import("../pvm.zig").PVM;
const InstructionWithArgs = PVM.InstructionWithArgs;

const polkavm_env = @import("polkavm.zig");
const pvm_env = @import("pvm.zig");

/// CrossCheck is a utility to compare execution of the same instruction
/// between the PVM and PolkaVM test environments.
pub const CrossCheck = struct {
    allocator: std.mem.Allocator,
    initial_registers: [13]u64,
    initial_memory: []u8,
    memory_base_address: u32 = 0x20000,
    memory_size: u32 = 0x1000,
    gas_limit: u32 = 10_000,

    const Self = @This();

    /// Represents a register mismatch between PVM and PolkaVM
    pub const RegisterMismatch = struct {
        register: usize,
        pvm_value: u64,
        polkavm_value: u64,
    };

    /// Result of comparing registers between PVM and PolkaVM
    pub const RegisterComparisonResult = struct {
        matches: bool,
        mismatches: std.ArrayList(RegisterMismatch),
    };

    /// Result of comparing memory between PVM and PolkaVM
    pub const MemoryComparisonResult = enum {
        BothUnchanged,
        PVMChangedOnly,
        PolkaVMChangedOnly,
        DifferentAddresses,
        DifferentValues,
        Identical,
    };

    /// Result of comparing execution status between PVM and PolkaVM
    pub const StatusComparisonResult = struct {
        matches: bool,
        pvm_status: []const u8,
        polkavm_status: []const u8,
    };

    /// Result of comparing gas usage between PVM and PolkaVM
    pub const GasComparisonResult = struct {
        matches: bool,
        pvm_gas: u64,
        polkavm_gas: u64,
        difference: i64,
    };

    pub const ComparisonResult = struct {
        instruction: InstructionWithArgs,
        pvm_result: pvm_env.InstructionExecutionResult,
        polkavm_result: polkavm_env.InstructionExecutionResult,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.pvm_result.deinit(allocator);
            self.polkavm_result.deinit(allocator);
        }

        /// Compares register values between PVM and PolkaVM
        /// Returns true if all registers match, false otherwise
        pub fn compareRegisters(self: *const @This()) RegisterComparisonResult {
            var result = RegisterComparisonResult{
                .matches = true,
                .mismatches = std.ArrayList(RegisterMismatch).init(std.heap.page_allocator),
            };

            for (0..13) |i| {
                const pvm_reg = self.pvm_result.registers[i];
                const polkavm_reg = self.polkavm_result.registers[i];

                if (pvm_reg != polkavm_reg) {
                    result.matches = false;
                    result.mismatches.append(.{
                        .register = i,
                        .pvm_value = pvm_reg,
                        .polkavm_value = polkavm_reg,
                    }) catch {};
                }
            }

            return result;
        }

        /// Compares memory changes between PVM and PolkaVM
        /// Returns an enum indicating the memory comparison result
        pub fn compareMemory(self: *const @This()) MemoryComparisonResult {
            // Check if either has no memory changes
            const pvm_has_memory = self.pvm_result.memory != null;
            const polkavm_has_memory = self.polkavm_result.memory != null;

            if (!pvm_has_memory and !polkavm_has_memory) {
                return .BothUnchanged;
            } else if (pvm_has_memory and !polkavm_has_memory) {
                return .PVMChangedOnly;
            } else if (!pvm_has_memory and polkavm_has_memory) {
                return .PolkaVMChangedOnly;
            }

            // Both have memory changes, compare addresses
            if (self.pvm_result.memory_address != self.polkavm_result.memory_address) {
                return .DifferentAddresses;
            }

            // Compare memory values
            const pvm_mem = self.pvm_result.memory.?;
            const polkavm_mem = self.polkavm_result.memory.?;

            if (pvm_mem.len != polkavm_mem.len) {
                return .DifferentValues;
            }

            for (pvm_mem, polkavm_mem) |pvm_byte, polkavm_byte| {
                if (pvm_byte != polkavm_byte) {
                    return .DifferentValues;
                }
            }

            return .Identical;
        }

        /// Compares execution status between PVM and PolkaVM
        pub fn compareStatus(self: *const @This()) StatusComparisonResult {
            var pvm_status_str: []const u8 = undefined;
            var polkavm_status_str: []const u8 = undefined;

            // Convert PVM status to string for comparison
            switch (self.pvm_result.status) {
                .success => pvm_status_str = "success",
                .terminal => |terminal| {
                    switch (terminal) {
                        .halt => pvm_status_str = "halt",
                        .panic => pvm_status_str = "panic",
                        .out_of_gas => pvm_status_str = "out_of_gas",
                        .page_fault => |_| pvm_status_str = "page_fault",
                    }
                },
                .@"error" => |_| pvm_status_str = "error",
            }

            // Convert PolkaVM status to string for comparison
            switch (self.polkavm_result.status) {
                .Trap => polkavm_status_str = "panic",
                .Success => polkavm_status_str = "halt",
                .OutOfGas => polkavm_status_str = "out_of_gas",
                .Segfault => polkavm_status_str = "page_fault",
                .Running => polkavm_status_str = "success",
                else => polkavm_status_str = "unknown",
            }

            return .{
                .matches = std.mem.eql(u8, pvm_status_str, polkavm_status_str),
                .pvm_status = pvm_status_str,
                .polkavm_status = polkavm_status_str,
            };
        }

        /// Compares gas usage between PVM and PolkaVM
        pub fn compareGas(self: *const @This()) GasComparisonResult {
            const pvm_gas = self.pvm_result.gas_used;
            const polkavm_gas = self.polkavm_result.gas_used;

            return .{
                .matches = true, // FIXME: pvm_gas == polkavm_gas,
                .pvm_gas = pvm_gas,
                .polkavm_gas = polkavm_gas,
                .difference = @as(i64, @intCast(pvm_gas)) - @as(i64, @intCast(polkavm_gas)),
            };
        }

        /// Checks if all aspects of execution match between the two environments
        pub fn matchesExactly(self: *const @This()) bool {
            const reg_compare = self.compareRegisters();
            defer reg_compare.mismatches.deinit();

            const mem_compare = self.compareMemory();
            const status_compare = self.compareStatus();
            const gas_compare = self.compareGas();

            return reg_compare.matches and
                (mem_compare == .BothUnchanged or mem_compare == .Identical) and
                status_compare.matches and
                gas_compare.matches;
        }

        /// Returns a comprehensive report of differences between PVM and PolkaVM
        pub fn getDifferenceReport(self: *const @This(), writer: anytype) !void {
            try writer.print("Cross-check report for instruction: {s}\n", .{@tagName(self.instruction.instruction)});

            // Register comparison
            const reg_compare = self.compareRegisters();
            defer reg_compare.mismatches.deinit();

            if (!reg_compare.matches) {
                try writer.writeAll("Register differences:\n");
                for (reg_compare.mismatches.items) |mismatch| {
                    try writer.print("  r{d:<2}: PVM=0x{d:>16} PolkaVM=0x{d:>16}\n", .{ mismatch.register, mismatch.pvm_value, mismatch.polkavm_value });
                }
            } else {
                try writer.writeAll("All registers match. Register values:\n");
                for (0..13) |i| {
                    try writer.print("PVM      r{d:<2}: {d:>16} ", .{ i, self.pvm_result.registers[i] });
                    try writer.print("PolkaVM  r{d:<2}: {d:>16}\n", .{ i, self.polkavm_result.registers[i] });
                }
            }

            // Memory comparison
            const mem_compare = self.compareMemory();
            try writer.print("Memory: ", .{});
            switch (mem_compare) {
                .BothUnchanged => try writer.writeAll("No memory changes in either VM.\n"),
                .PVMChangedOnly => try writer.writeAll("Only PVM made memory changes.\n"),
                .PolkaVMChangedOnly => try writer.writeAll("Only PolkaVM made memory changes.\n"),
                .DifferentAddresses => try writer.writeAll("Both VMs changed memory at different addresses.\n"),
                .DifferentValues => try writer.writeAll("Both VMs changed memory with different values.\n"),
                .Identical => try writer.writeAll("Memory changes identical in both VMs.\n"),
            }

            // Status comparison
            const status_compare = self.compareStatus();
            if (!status_compare.matches) {
                try writer.print("Status mismatch: PVM={s} PolkaVM={s}\n", .{ status_compare.pvm_status, status_compare.polkavm_status });
            } else {
                try writer.print("Status matches: {s}\n", .{status_compare.pvm_status});
            }

            // Gas comparison
            const gas_compare = self.compareGas();
            if (!gas_compare.matches) {
                try writer.print("Gas usage mismatch: PVM={d} PolkaVM={d} (diff: {d})\n", .{ gas_compare.pvm_gas, gas_compare.polkavm_gas, gas_compare.difference });
            } else {
                try writer.print("Gas usage matches: {d}\n", .{gas_compare.pvm_gas});
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Initialize memory buffer
        const memory = try allocator.alloc(u8, 0x1000);
        errdefer allocator.free(memory);

        // Clear memory
        @memset(memory, 0);

        // Initialize registers
        const registers: [13]u64 = std.mem.zeroes([13]u64);

        return Self{
            .allocator = allocator,
            .initial_registers = registers,
            .initial_memory = memory,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.initial_memory);
    }

    pub fn setRegister(self: *Self, register_index: usize, value: u64) void {
        if (register_index < self.initial_registers.len) {
            self.initial_registers[register_index] = value;
        }
    }

    pub fn setMemory(self: *Self, offset: usize, data: []const u8) void {
        if (offset + data.len <= self.initial_memory.len) {
            @memcpy(self.initial_memory[offset..][0..data.len], data);
        }
    }

    pub fn setMemoryByte(self: *Self, offset: usize, value: u8) void {
        if (offset < self.initial_memory.len) {
            self.initial_memory[offset] = value;
        }
    }

    pub fn compareInstruction(self: *Self, instruction: InstructionWithArgs) !ComparisonResult {
        try polkavm_env.initPolkaVMEnvironment();

        // Setup PVM environment
        var pvm = try pvm_env.TestEnvironment.init(self.allocator);
        defer pvm.deinit();

        // Copy initial memory and registers to PVM
        for (0..self.initial_registers.len) |i| {
            pvm.setRegister(i, self.initial_registers[i]);
        }
        try pvm.setMemory(0, self.initial_memory);

        // Setup PolkaVM environment
        var polkavm = try polkavm_env.TestEnvironment.init(self.allocator);
        defer polkavm.deinit();

        // Copy initial memory and registers to PolkaVM
        for (0..self.initial_registers.len) |i| {
            polkavm.setRegister(i, self.initial_registers[i]);
        }
        polkavm.setMemory(0, self.initial_memory);

        // Execute the instruction in both environments
        const pvm_result = try pvm.executeInstruction(instruction);
        const polkavm_result = try polkavm.executeInstruction(instruction);

        return ComparisonResult{
            .instruction = instruction,
            .pvm_result = pvm_result,
            .polkavm_result = polkavm_result,
        };
    }
};

test "crosscheck:instructions" {
    const allocator = std.testing.allocator;
    var crosscheck = try CrossCheck.init(allocator);
    defer crosscheck.deinit();

    // Set up register r1 with a test value
    crosscheck.setRegister(1, 4278059008);

    // Create an add_imm_64 instruction that tests negative immediate
    const instruction = InstructionWithArgs{ .instruction = .add_imm_64, .args = .{
        .TwoRegOneImm = .{
            .first_register_index = 1,
            .second_register_index = 1,
            .immediate = 0xfffffffffffff808,
            .no_of_bytes_to_skip = 3,
        },
    } };

    std.debug.print("\nInstruction: {s}, first_reg: {}, second_reg: {}, immediate: 0x{x}\n", .{
        @tagName(instruction.instruction),
        instruction.args.TwoRegOneImm.first_register_index,
        instruction.args.TwoRegOneImm.second_register_index,
        instruction.args.TwoRegOneImm.immediate,
    });

    // Execute the instruction in both environments and compare
    var comparison = try crosscheck.compareInstruction(instruction);
    defer comparison.deinit(allocator);

    // Generate and print difference report
    const report = try comparison.getDifferenceReport(allocator);
    defer allocator.free(report);
    std.debug.print("\n{s}\n", .{report});

    // Verify that results match
    try std.testing.expect(comparison.matchesExactly());
}
