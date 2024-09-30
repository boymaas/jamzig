const std = @import("std");
const Allocator = std.mem.Allocator;
const Instruction = @import("./pvm/instruction.zig").Instruction;
const Program = @import("./pvm/program.zig").Program;
const Decoder = @import("./pvm/decoder.zig").Decoder;
const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;

const updatePc = @import("./pvm/utils.zig").updatePc;

pub const PVM = struct {
    allocator: Allocator,
    program: Program,
    registers: [13]u32,
    pc: u32,
    memory: []MemoryChunk,
    page_map: []PageMap,
    gas: i64,

    pub const PageMap = struct {
        address: u32,
        length: u32,
        is_writable: bool,
    };

    pub const MemoryChunk = struct {
        address: u32,
        contents: []u8,
    };

    pub const Status = enum {
        trap,
        halt,
    };

    pub fn init(allocator: Allocator, raw_program: []const u8, initial_gas: i64) !PVM {
        const program = try Program.decode(allocator, raw_program);

        return PVM{
            .allocator = allocator,
            .program = program,
            .registers = [_]u32{0} ** 13,
            .pc = 0,
            .page_map = &[_]PageMap{},
            .memory = &[_]MemoryChunk{},
            .gas = initial_gas,
        };
    }

    pub fn deinit(self: *PVM) void {
        self.program.deinit(self.allocator);
        self.allocator.free(self.page_map);
        for (self.memory) |chunk| {
            self.allocator.free(chunk.contents);
        }
        self.allocator.free(self.memory);
    }

    pub fn pushMemory(self: *PVM, address: u32, contents: []const u8) !void {
        const new_chunk = MemoryChunk{
            .address = address,
            .contents = try self.allocator.dupe(u8, contents),
        };
        const new_memory = try self.allocator.realloc(self.memory, self.memory.len + 1);
        new_memory[self.memory.len] = new_chunk;
        self.memory = new_memory;
    }

    pub fn setPageMap(self: *PVM, new_page_map: []const PageMap) !void {
        self.allocator.free(self.page_map);
        self.page_map = try self.allocator.dupe(PageMap, new_page_map);
    }

    pub fn decompilePrint(self: *PVM) !void {
        const decoder = Decoder.init(self.program.code, self.program.mask);
        var pc: u32 = 0;

        while (pc < self.program.code.len) {
            const i = try decoder.decodeInstruction(pc);

            std.debug.print("{d:0>4}: {any}\n", .{ pc, i });
            pc += i.skip_l() + 1;
            break;
        }
    }

    const MAX_ITERATIONS = 1024;

    fn getGasCost(instruction: InstructionWithArgs) u32 {
        return switch (instruction.instruction) {
            .trap => 0,
            .load_u8 => 1,
            else => 1,
        };
    }

    pub fn run(self: *PVM) !void {
        const decoder = Decoder.init(self.program.code, self.program.mask);
        var n: usize = 0;
        while (n < MAX_ITERATIONS) : (n += 1) {
            const i = try decoder.decodeInstruction(self.pc);

            const gas_cost = getGasCost(i);
            if (self.gas < gas_cost) {
                return error.OUT_OF_GAS;
            }

            self.gas -= gas_cost;
            self.pc = try updatePc(self.pc, self.executeInstruction(i) catch |err| {
                self.gas -= switch (err) {
                    error.JumpAddressHalt => 0,
                    error.JumpAddressZero => 0,
                    else => 1,
                }; // Charge one extra gas for error handling
                return err;
            });
        }

        if (n == MAX_ITERATIONS) {
            return error.MAX_ITERATIONS_REACHED;
        }
    }

    /// Offset to add to the program counter
    const PcOffset = i32;
    /// executes the instruction and returns the offset to add to the program counter
    fn executeInstruction(self: *PVM, i: InstructionWithArgs) !PcOffset {
        switch (i.instruction) {
            .trap => {
                // Halt the program
                return error.PANIC;
            },
            .load_imm => {
                // Load immediate value into register
                const args = i.args.one_register_one_immediate;
                self.registers[args.register_index] = @bitCast(args.immediate);
            },
            .jump => {
                // Jump to offset
                const args = i.args.one_offset;
                return args.offset;
            },
            .add_imm => {
                // Add immediate value to register
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = @addWithOverflow(
                    self.registers[args.second_register_index],
                    @as(u32, @bitCast(args.immediate)),
                )[0];
            },
            .move_reg => {
                const args = i.args.two_registers;
                self.registers[args.first_register_index] = self.registers[args.second_register_index];
            },
            .fallthrough => {
                // Do nothing, just move to the next instruction
            },
            .add => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = @addWithOverflow(
                    self.registers[args.first_register_index],
                    self.registers[args.second_register_index],
                )[0];
            },
            .@"and" => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = self.registers[args.first_register_index] & self.registers[args.second_register_index];
            },
            .and_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] & @as(u32, @bitCast(args.immediate));
            },
            .xor_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] ^ @as(u32, @bitCast(args.immediate));
            },
            .or_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] | @as(u32, @bitCast(args.immediate));
            },
            .mul_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = @mulWithOverflow(self.registers[args.second_register_index], @as(u32, @bitCast(args.immediate)))[0];
            },
            .mul_upper_s_s_imm => {
                const args = i.args.two_registers_one_immediate;
                const result = @as(i64, @intCast(@as(i32, @bitCast(self.registers[args.second_register_index])))) * @as(i64, @intCast(args.immediate));
                self.registers[args.first_register_index] = @as(u32, @bitCast(@as(i32, @intCast(result >> 32))));
            },
            .mul_upper_u_u_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] *% @as(u32, @bitCast(args.immediate));
            },
            .set_lt_u_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = if (self.registers[args.second_register_index] < @as(u32, @bitCast(args.immediate))) 1 else 0;
            },
            .set_lt_s_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = if (@as(i32, @bitCast(self.registers[args.second_register_index])) < @as(i32, @bitCast(args.immediate))) 1 else 0;
            },
            .shlo_l_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] << @intCast(args.immediate % 32);
            },
            .shlo_l_imm_alt => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = args.immediate << @intCast(self.registers[args.second_register_index] % 32);
            },
            .shlo_r_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] >> @intCast(args.immediate % 32);
            },
            .shlo_r_imm_alt => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = args.immediate >> @intCast(self.registers[args.second_register_index] % 32);
            },
            .shar_r_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = @bitCast(
                    @as(i32, @bitCast(self.registers[args.second_register_index])) >> @intCast(args.immediate % 32),
                );
            },
            .shar_r_imm_alt => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = @bitCast(
                    @as(i32, @bitCast(args.immediate)) >> @intCast(self.registers[args.second_register_index] % 32),
                );
            },
            .neg_add_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = args.immediate -% self.registers[args.second_register_index];
            },
            .set_gt_u_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = if (self.registers[args.second_register_index] > args.immediate) 1 else 0;
            },
            .set_gt_s_imm => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = if (@as(i32, @bitCast(self.registers[args.second_register_index])) > @as(i32, @bitCast(args.immediate))) 1 else 0;
            },
            .cmov_iz_imm => {
                const args = i.args.two_registers_one_immediate;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.first_register_index] = @bitCast(args.immediate);
                }
            },
            .cmov_nz_imm => {
                const args = i.args.two_registers_one_immediate;
                if (self.registers[args.second_register_index] != 0) {
                    self.registers[args.first_register_index] = @bitCast(args.immediate);
                }
            },
            .sub => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = @subWithOverflow(self.registers[args.first_register_index], self.registers[args.second_register_index])[0];
            },
            .xor => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = self.registers[args.first_register_index] ^ self.registers[args.second_register_index];
            },
            .@"or" => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = self.registers[args.first_register_index] | self.registers[args.second_register_index];
            },
            .mul => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = @mulWithOverflow(self.registers[args.first_register_index], self.registers[args.second_register_index])[0];
            },
            .mul_upper_s_s => {
                const args = i.args.three_registers;
                const result = @as(i64, @intCast(@as(i32, @bitCast(self.registers[args.first_register_index])))) * @as(i64, @intCast(@as(i32, @bitCast(self.registers[args.second_register_index]))));
                self.registers[args.third_register_index] = @as(u32, @bitCast(@as(i32, @intCast(result >> 32))));
            },
            .mul_upper_u_u => {
                const args = i.args.three_registers;
                const result = @as(u64, self.registers[args.first_register_index]) * @as(u64, self.registers[args.second_register_index]);
                self.registers[args.third_register_index] = @intCast(result >> 32);
            },
            .mul_upper_s_u => {
                const args = i.args.three_registers;
                const result = @as(i64, @intCast(@as(i32, @bitCast(self.registers[args.first_register_index])))) * @as(i64, self.registers[args.second_register_index]);
                self.registers[args.third_register_index] = @as(u32, @bitCast(@as(i32, @intCast(result >> 32))));
            },
            .div_u => {
                const args = i.args.three_registers;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = 0xFFFFFFFF;
                } else {
                    self.registers[args.third_register_index] = @divTrunc(self.registers[args.first_register_index], self.registers[args.second_register_index]);
                }
            },
            .div_s => {
                const args = i.args.three_registers;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = 0xFFFFFFFF;
                } else if (self.registers[args.first_register_index] == 0x80000000 and
                    self.registers[args.second_register_index] == 0xFFFFFFFF)
                {
                    self.registers[args.third_register_index] = 0x80000000;
                } else {
                    self.registers[args.third_register_index] = @as(u32, @bitCast(@divTrunc(@as(i32, @bitCast(self.registers[args.first_register_index])), @as(i32, @bitCast(self.registers[args.second_register_index])))));
                }
            },
            .rem_u => {
                const args = i.args.three_registers;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                } else {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index] % self.registers[args.second_register_index];
                }
            },
            .rem_s => {
                const args = i.args.three_registers;

                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                } else if (self.registers[args.first_register_index] == 0x80000000 and
                    self.registers[args.second_register_index] == 0xFFFFFFFF)
                {
                    self.registers[args.third_register_index] = 0x00;
                } else {
                    self.registers[args.third_register_index] = @as(
                        u32,
                        @bitCast(@rem(
                            @as(
                                i32,
                                @bitCast(self.registers[args.first_register_index]),
                            ),
                            @as(
                                i32,
                                @bitCast(self.registers[args.second_register_index]),
                            ),
                        )),
                    );
                }
            },
            .set_lt_u => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = if (self.registers[args.first_register_index] < self.registers[args.second_register_index]) 1 else 0;
            },
            .set_lt_s => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = if (@as(i32, @bitCast(self.registers[args.first_register_index])) < @as(i32, @bitCast(self.registers[args.second_register_index]))) 1 else 0;
            },
            .shlo_l => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = self.registers[args.first_register_index] << @intCast(self.registers[args.second_register_index] & 0x1F);
            },
            .shlo_r => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = self.registers[args.first_register_index] >> @intCast(self.registers[args.second_register_index] & 0x1F);
            },
            .shar_r => {
                const args = i.args.three_registers;
                self.registers[args.third_register_index] = @as(u32, @bitCast(@as(i32, @bitCast(self.registers[args.first_register_index])) >> @intCast(self.registers[args.second_register_index] & 0x1F)));
            },
            .cmov_iz => {
                const args = i.args.three_registers;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                }
            },
            .cmov_nz => {
                const args = i.args.three_registers;
                if (self.registers[args.second_register_index] != 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                }
            },
            .ecalli => {
                const args = i.args.one_immediate;
                // Implement ecalli behavior here
                // For now, we'll just print the immediate value
                std.debug.print("ECALL with immediate: {}\n", .{args.immediate});
            },
            .store_imm_u8 => {
                const args = i.args.two_immediates;
                try self.storeMemory(args.first_immediate, @intCast(args.second_immediate), 1);
            },
            .store_imm_u16 => {
                const args = i.args.two_immediates;
                try self.storeMemory(args.first_immediate, @intCast(args.second_immediate), 2);
            },
            .store_imm_u32 => {
                const args = i.args.two_immediates;
                try self.storeMemory(args.first_immediate, args.second_immediate, 4);
            },
            .jump_ind => {
                const args = i.args.one_register_one_immediate;
                return self.djump(self.registers[args.register_index] +% args.immediate);
            },
            .load_u8 => {
                const args = i.args.one_register_one_immediate;
                self.registers[args.register_index] = try self.loadMemory(args.immediate, 1);
            },
            .load_i8 => {
                const args = i.args.one_register_one_immediate;
                const value = try self.loadMemory(args.immediate, 1);
                self.registers[args.register_index] = @as(u32, @bitCast(@as(i32, @intCast(@as(i8, @bitCast(@as(u8, @truncate(value))))))));
            },
            .load_u16 => {
                const args = i.args.one_register_one_immediate;
                self.registers[args.register_index] = try self.loadMemory(args.immediate, 2);
            },
            .load_i16 => {
                const args = i.args.one_register_one_immediate;
                const value = try self.loadMemory(args.immediate, 2);
                self.registers[args.register_index] = @as(u32, @bitCast(@as(i32, @intCast(@as(i16, @bitCast(@as(u16, @truncate(value))))))));
            },
            .load_u32 => {
                const args = i.args.one_register_one_immediate;
                self.registers[args.register_index] = try self.loadMemory(args.immediate, 4);
            },
            .store_u8 => {
                const args = i.args.one_register_one_immediate;
                try self.storeMemory(args.immediate, @truncate(self.registers[args.register_index]), 1);
            },
            .store_u16 => {
                const args = i.args.one_register_one_immediate;
                try self.storeMemory(args.immediate, @truncate(self.registers[args.register_index]), 2);
            },
            .store_u32 => {
                const args = i.args.one_register_one_immediate;
                try self.storeMemory(args.immediate, self.registers[args.register_index], 4);
            },
            .store_imm_ind_u8 => {
                const args = i.args.one_register_two_immediates;
                try self.storeMemory(self.registers[args.register_index] +% @as(u32, @bitCast(args.first_immediate)), @intCast(args.second_immediate), 1);
            },
            .store_imm_ind_u16 => {
                const args = i.args.one_register_two_immediates;
                try self.storeMemory(self.registers[args.register_index] +% @as(u32, @bitCast(args.first_immediate)), @intCast(args.second_immediate), 2);
            },
            .store_imm_ind_u32 => {
                const args = i.args.one_register_two_immediates;
                try self.storeMemory(self.registers[args.register_index] +% @as(u32, @bitCast(args.first_immediate)), args.second_immediate, 4);
            },
            .load_imm_jump => {
                const args = i.args.one_register_one_immediate_one_offset;
                self.registers[args.register_index] = @bitCast(args.immediate);
                return try self.branch(args.next_pc);
            },
            .branch_eq_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] == args.immediate) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_ne_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] != args.immediate) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_lt_u_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] < args.immediate) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_le_u_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] <= args.immediate) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_ge_u_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] >= args.immediate) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_gt_u_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (self.registers[args.register_index] > args.immediate) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_lt_s_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (@as(i32, @bitCast(self.registers[args.register_index])) < @as(i32, @bitCast(args.immediate))) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_le_s_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (@as(i32, @bitCast(self.registers[args.register_index])) <= @as(i32, @bitCast(args.immediate))) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_ge_s_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (@as(i32, @bitCast(self.registers[args.register_index])) >= @as(i32, @bitCast(args.immediate))) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_gt_s_imm => {
                const args = i.args.one_register_one_immediate_one_offset;
                if (@as(i32, @bitCast(self.registers[args.register_index])) > @as(i32, @bitCast(args.immediate))) {
                    return try self.branch(args.next_pc);
                }
            },
            .sbrk => {
                const args = i.args.two_registers;
                // Implement sbrk behavior here
                // For now, we'll just print a message
                std.debug.print("SBRK called with registers r{} and r{}\n", .{ args.first_register_index, args.second_register_index });
            },
            .store_ind_u8 => {
                const args = i.args.two_registers_one_immediate;
                try self.storeMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), @truncate(self.registers[args.first_register_index]), 1);
            },
            .store_ind_u16 => {
                const args = i.args.two_registers_one_immediate;
                try self.storeMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), @truncate(self.registers[args.first_register_index]), 2);
            },
            .store_ind_u32 => {
                const args = i.args.two_registers_one_immediate;
                try self.storeMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), self.registers[args.first_register_index], 4);
            },
            .load_ind_u8 => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = try self.loadMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), 1);
            },
            .load_ind_i8 => {
                const args = i.args.two_registers_one_immediate;
                const value = try self.loadMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), 1);
                self.registers[args.first_register_index] = @as(u32, @bitCast(@as(i32, @intCast(@as(i8, @bitCast(@as(u8, @truncate(value))))))));
            },
            .load_ind_u16 => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = try self.loadMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), 2);
            },
            .load_ind_i16 => {
                const args = i.args.two_registers_one_immediate;
                const value = try self.loadMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), 2);
                self.registers[args.first_register_index] = @as(u32, @bitCast(@as(i32, @intCast(@as(i16, @bitCast(@as(u16, @truncate(value))))))));
            },
            .load_ind_u32 => {
                const args = i.args.two_registers_one_immediate;
                self.registers[args.first_register_index] = try self.loadMemory(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.immediate)), 4);
            },
            .branch_eq => {
                const args = i.args.two_registers_one_offset;
                if (self.registers[args.first_register_index] == self.registers[args.second_register_index]) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_ne => {
                const args = i.args.two_registers_one_offset;
                if (self.registers[args.first_register_index] != self.registers[args.second_register_index]) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_lt_u => {
                const args = i.args.two_registers_one_offset;
                if (self.registers[args.first_register_index] < self.registers[args.second_register_index]) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_lt_s => {
                const args = i.args.two_registers_one_offset;
                if (@as(i32, @bitCast(self.registers[args.first_register_index])) < @as(i32, @bitCast(self.registers[args.second_register_index]))) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_ge_u => {
                const args = i.args.two_registers_one_offset;
                if (self.registers[args.first_register_index] >= self.registers[args.second_register_index]) {
                    return try self.branch(args.next_pc);
                }
            },
            .branch_ge_s => {
                const args = i.args.two_registers_one_offset;
                if (@as(i32, @bitCast(self.registers[args.first_register_index])) >= @as(i32, @bitCast(self.registers[args.second_register_index]))) {
                    return try self.branch(args.next_pc);
                }
            },
            .load_imm_jump_ind => {
                const args = i.args.two_registers_two_immediates;
                self.registers[args.first_register_index] = @bitCast(args.first_immediate);
                return @intCast(self.registers[args.second_register_index] +% @as(u32, @bitCast(args.second_immediate)));
            },
        }

        // default offset
        return @intCast(i.skip_l() + 1);
    }

    fn branch(self: *PVM, b: u32) !PcOffset {
        // Check if the target address is the start of a basic block
        if (!self.isBasicBlockStart(b)) {
            return error.PANIC; // Panic if not jumping to a basic block start
        }

        // Calculate the offset to the target address
        const offset: i32 = @as(i32, @intCast(b)) - @as(i32, @intCast(self.pc));
        std.debug.print("branching to {}\n", .{b});
        std.debug.print("branching to offset {}\n", .{offset});
        return offset;
    }

    pub fn djump(
        self: *PVM,
        a: u32,
    ) !PcOffset {
        // const halt_pc = 2 ** 32 - 2 ** 16;
        const halt_pc = 0xFFFF0000;
        const ZA = 2;

        // 1. Check if a is equal to the special halt value
        if (a == halt_pc) {
            return error.JumpAddressHalt;
        }

        // 2. Check if the value of `a` is invalid
        if (a == 0) {
            return error.JumpAddressZero;
        }
        if (a > self.program.jump_table.len() * ZA) {
            return error.JumpAddressOutOfRange;
        }
        if (a % ZA != 0) {
            return error.JumpAddressNotAligned;
        }

        // 3. Compute the jump index and check if it is in the valid destinations set
        const index = (a / ZA) - 1;
        const jump_dest = self.program.jump_table.getDestination(index);
        if (std.mem.indexOfScalar(u32, self.program.basic_blocks, jump_dest) == null) {
            return error.JumpAddressInvalid;
        }

        // 4. Jump to the destination by calculating the offset
        return @as(i32, @intCast(@as(i32, @bitCast(jump_dest)) - @as(i32, @bitCast(self.pc))));
    }

    fn isBasicBlockStart(self: *PVM, address: u32) bool {
        // Check if the address is in the list of basic block starts
        return std.mem.indexOfScalar(u32, self.program.basic_blocks, address) != null;
    }

    fn loadMemory(self: *PVM, address: u32, size: u8) !u32 {
        const u_address = @as(u32, @bitCast(address));
        for (self.page_map) |page| {
            if (u_address >= page.address and u_address < page.address + page.length) {
                for (self.memory) |chunk| {
                    if (u_address >= chunk.address and u_address < chunk.address + chunk.contents.len) {
                        const offset = u_address - chunk.address;
                        var result: u32 = 0;
                        var i: u8 = 0;
                        while (i < size) : (i += 1) {
                            if (offset + i >= chunk.contents.len) {
                                return error.MemoryAccessOutOfBounds;
                            }
                            result |= @as(u32, chunk.contents[offset + i]) << @as(u5, @intCast(i * 8));
                        }
                        return result;
                    }
                }
                return error.MemoryChunkNotFound;
            }
        }
        return error.MemoryAccessOutOfBounds;
    }

    fn storeMemory(self: *PVM, address: u32, value: u32, size: u8) !void {
        const u_address = @as(u32, @bitCast(address));
        for (self.page_map) |page| {
            if (u_address >= page.address and u_address < page.address + page.length) {
                if (!page.is_writable) {
                    return error.MemoryWriteProtected;
                }
                for (self.memory) |*chunk| {
                    if (u_address >= chunk.address and u_address < chunk.address + chunk.contents.len) {
                        const offset = u_address - chunk.address;
                        var i: u8 = 0;
                        while (i < size) : (i += 1) {
                            if (offset + i >= chunk.contents.len) {
                                return error.MemoryAccessOutOfBounds;
                            }
                            chunk.contents[offset + i] = @truncate(value >> @intCast(i * 8));
                        }
                        return;
                    }
                }
                return error.MemoryChunkNotFound;
            }
        }
        return error.MemoryAccessOutOfBounds;
    }
};
