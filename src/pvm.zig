const std = @import("std");
const Allocator = std.mem.Allocator;

const trace = @import("tracing.zig").scoped(.pvm);

// Separated execution result into its own type
pub const ExecutionResult = union(enum) {
    halt: []const u8,
    err: ExecutionError,

    pub const ExecutionError = union(enum) {
        panic,
        out_of_gas,
        page_fault: u32,
        host_call: u32,
    };
};

pub const ExecutionStepResult = union(enum) {
    // Continue execution with next instruction
    cont: void,
    // Need to execute host call
    host_call: struct {
        /// Host call index
        idx: u32,
        /// Next PC after host call
        next_pc: u32,
    },
    // Terminal conditions from graypaper
    terminal: union(enum) {
        halt: []const u8, // ∎ Regular halt
        panic: void, // ☇ Panic
        out_of_gas: void, // ∞ Out of gas
        page_fault: u32, // F Page fault
    },
};

pub const PVM = struct {
    pub const Program = @import("./pvm/program.zig").Program;
    pub const Decoder = @import("./pvm/decoder.zig").Decoder;

    pub const Instruction = @import("./pvm/instruction.zig").Instruction;
    pub const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;

    pub const Memory = @import("./pvm/memory.zig").Memory;

    pub const HostCallFn = @import("./pvm/host_calls.zig").HostCallFn;
    pub const HostCallResult = @import("./pvm/host_calls.zig").HostCallResult;

    pub const ExecutionContext = @import("./pvm/execution_context.zig").ExecutionContext;

    pub const Result = ExecutionResult;

    const updatePc = @import("./pvm/utils.zig").updatePc;

    pub const Error = error{
        // PcRelated errors
        PcUnderflow,

        // Memory related errors
        MemoryPageFault,
        MemoryAccessOutOfBounds,
        MemoryWriteProtected,

        // Jump/Branch related errors
        JumpAddressHalt,
        JumpAddressZero,
        JumpAddressOutOfRange,
        JumpAddressNotAligned,
        JumpAddressNotInBasicBlock,

        // Host call related errors
        NonExistentHostCall,

        UnimplementedInstruction,

        // Execution related errors
        OutOfGas,
        Trap,
    } || Decoder.Error || Program.Error || Memory.Error || error{
        OutOfMemory,
        EmptyBuffer,
        InsufficientData,
        SectionNotFound,
        NonAllocatedMemoryAccess,
        DivisionByZero,
    };

    pub fn executeStep(context: *ExecutionContext) Error!ExecutionStepResult {
        const span = trace.span(.execute_step);
        defer span.deinit();

        // Decode instruction
        const instruction = try context.decoder.decodeInstruction(context.pc);
        span.debug("Executing instruction at PC: 0x{d:0>8}: {}", .{ context.pc, instruction });
        span.trace("Decoded instruction: {}", .{instruction.instruction});

        // Check gas
        const gas_cost = getInstructionGasCost(instruction);
        span.trace("Instruction gas cost: {d}", .{gas_cost});

        if (context.gas < gas_cost) {
            span.debug("Out of gas - remaining: {d}, required: {d}", .{ context.gas, gas_cost });
            return .{ .terminal = .out_of_gas };
        }
        context.gas -= gas_cost;
        span.trace("Remaining gas: {d}", .{context.gas});

        // Execute instruction
        return executeInstruction(context, instruction);
    }

    pub fn execute(
        context: *ExecutionContext,
    ) Error!ExecutionResult {
        while (true) {
            const step_result = try executeStep(context);
            switch (step_result) {
                .cont => continue,
                .host_call => |host| {
                    // Get host call handler
                    const handler = context.host_calls.get(host.idx) orelse
                        return .{ .err = .{ .host_call = host.idx } };

                    // Execute host call
                    const result = handler(&context.gas, &context.registers, &context.memory);
                    switch (result) {
                        .play => {
                            context.pc = host.next_pc;
                            continue;
                        },
                        .page_fault => |addr| return .{ .err = .{ .page_fault = addr } },
                    }
                },
                .terminal => |result| switch (result) {
                    .halt => |output| return .{ .halt = output },
                    .panic => return .{ .err = .panic },
                    .out_of_gas => return .{ .err = .out_of_gas },
                    .page_fault => |addr| return .{ .err = .{ .page_fault = addr } },
                },
            }
        }
    }

    fn getInstructionGasCost(instruction: InstructionWithArgs) u32 {
        _ = instruction;
        return 1; // Default cost, can be made more sophisticated
    }

    const PcOffset = i32;
    fn executeInstruction(context: *ExecutionContext, i: InstructionWithArgs) Error!ExecutionStepResult {
        switch (i.instruction) {
            // A.5.1 Instructions without Arguments
            .trap => return .{ .terminal = .panic },
            .fallthrough => {},

            // A.5.2 Instructions with Arguments of One Immediate
            .ecalli => {
                const args = i.args.OneImm;
                // Return host call for execution by executeStep
                return .{ .host_call = .{
                    .idx = @truncate(args.immediate),
                    .next_pc = context.pc + i.skip_l() + 1,
                } };
            },

            // A.5.3 Instructions with Arguments of One Register and One Extended Width Immediate
            .load_imm_64 => {
                const args = i.args.OneRegOneExtImm;
                context.registers[args.register_index] = args.immediate;
            },

            // A.5.4 Instructions with Arguments of Two Immediates
            .store_imm_u8, .store_imm_u16, .store_imm_u32, .store_imm_u64 => {
                const args = i.args.TwoImm;
                var bytes: [8]u8 = undefined;

                switch (i.instruction) {
                    .store_imm_u8 => bytes[0] = @truncate(args.second_immediate),
                    .store_imm_u16 => std.mem.writeInt(u16, bytes[0..2], @truncate(args.second_immediate), .little),
                    .store_imm_u32 => std.mem.writeInt(u32, bytes[0..4], @truncate(args.second_immediate), .little),
                    .store_imm_u64 => std.mem.writeInt(u64, bytes[0..8], args.second_immediate, .little),
                    else => unreachable,
                }

                const size: usize = switch (i.instruction) {
                    .store_imm_u8 => 1,
                    .store_imm_u16 => 2,
                    .store_imm_u32 => 4,
                    .store_imm_u64 => 8,
                    else => unreachable,
                };

                context.memory.write(@truncate(args.first_immediate), bytes[0..size]) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(args.first_immediate) } };
                    }
                    return err;
                };
            },

            // A.5.5 Instructions with Arguments of One Offset
            .jump => {
                // TODO: catch potential errors and return the correct ExecutionResult
                context.pc = updatePc(context.pc, i.args.OneOffset.offset) catch {
                    return .{ .terminal = .panic };
                };
                return .cont;
            },

            // A.5.6 Instructions with Arguments of One Register & One Immediate
            .jump_ind => {
                const args = i.args.OneRegOneImm;
                const jump_dest = context.program.validateJumpAddress(
                    @truncate(context.registers[args.register_index] +| args.immediate),
                ) catch |err| {
                    return if (err == error.JumpAddressHalt)
                        .{ .terminal = .{ .halt = &[_]u8{} } }
                    else
                        .{ .terminal = .panic };
                };
                context.pc = jump_dest;
                return .cont;
            },

            .load_imm => {
                const args = i.args.OneRegOneImm;
                context.registers[args.register_index] = args.immediate;
            },

            .load_u8, .load_i8, .load_u16, .load_i16, .load_u32, .load_i32, .load_u64 => {
                const args = i.args.OneRegOneImm;
                const data = context.memory.read(@truncate(args.immediate), switch (i.instruction) {
                    .load_u8, .load_i8 => 1,
                    .load_u16, .load_i16 => 2,
                    .load_u32, .load_i32 => 4,
                    .load_u64 => 8,
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        // FIXME: must be lowest address wich triggered the page_fault
                        return .{ .terminal = .{ .page_fault = @truncate(args.immediate) } };
                    }
                    return err;
                };

                context.registers[args.register_index] = switch (i.instruction) {
                    .load_u8 => data[0],
                    .load_i8 => @bitCast(@as(i64, @intCast(@as(i8, @bitCast(data[0]))))),
                    .load_u16 => std.mem.readInt(u16, data[0..2], .little),
                    .load_i16 => @bitCast(@as(i64, @intCast(@as(i16, @bitCast(std.mem.readInt(u16, data[0..2], .little)))))),
                    .load_u32 => std.mem.readInt(u32, data[0..4], .little),
                    .load_i32 => @bitCast(@as(i64, @intCast(@as(i32, @bitCast(std.mem.readInt(u32, data[0..4], .little)))))),
                    .load_u64 => std.mem.readInt(u64, data[0..8], .little),
                    else => unreachable,
                };
            },

            .store_u8, .store_u16, .store_u32, .store_u64 => {
                const args = i.args.OneRegOneImm;
                var bytes: [8]u8 = undefined;
                const value = context.registers[args.register_index];

                switch (i.instruction) {
                    .store_u8 => bytes[0] = @truncate(value),
                    .store_u16 => std.mem.writeInt(u16, bytes[0..2], @truncate(value), .little),
                    .store_u32 => std.mem.writeInt(u32, bytes[0..4], @truncate(value), .little),
                    .store_u64 => std.mem.writeInt(u64, bytes[0..8], value, .little),
                    else => unreachable,
                }

                const size: usize = switch (i.instruction) {
                    .store_u8 => 1,
                    .store_u16 => 2,
                    .store_u32 => 4,
                    .store_u64 => 8,
                    else => unreachable,
                };

                context.memory.write(@truncate(args.immediate), bytes[0..size]) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(args.immediate) } };
                    }
                    return err;
                };
            },

            // A.5.7 Instructions with Arguments of One Register & Two Immediates
            .store_imm_ind_u8, .store_imm_ind_u16, .store_imm_ind_u32, .store_imm_ind_u64 => {
                const args = i.args.OneRegTwoImm;
                var bytes: [8]u8 = undefined;

                switch (i.instruction) {
                    .store_imm_ind_u8 => bytes[0] = @truncate(args.second_immediate),
                    .store_imm_ind_u16 => std.mem.writeInt(u16, bytes[0..2], @truncate(args.second_immediate), .little),
                    .store_imm_ind_u32 => std.mem.writeInt(u32, bytes[0..4], @truncate(args.second_immediate), .little),
                    .store_imm_ind_u64 => std.mem.writeInt(u64, bytes[0..8], args.second_immediate, .little),
                    else => unreachable,
                }

                const size: usize = switch (i.instruction) {
                    .store_imm_ind_u8 => 1,
                    .store_imm_ind_u16 => 2,
                    .store_imm_ind_u32 => 4,
                    .store_imm_ind_u64 => 8,
                    else => unreachable,
                };

                const addr = context.registers[args.register_index] +% args.first_immediate;
                context.memory.write(@truncate(addr), bytes[0..size]) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };
            },

            // A.5.8 Instructions with Arguments of One Register, One Immediate and One Offset
            .load_imm_jump => {
                const args = i.args.OneRegOneImmOneOffset;
                context.registers[args.register_index] = args.immediate;
                context.pc = updatePc(context.pc, args.offset) catch {
                    return .{ .terminal = .panic };
                };
                return .cont;
            },

            // Branch instructions
            .branch_eq_imm, .branch_ne_imm, .branch_lt_u_imm, .branch_le_u_imm, .branch_ge_u_imm, .branch_gt_u_imm, .branch_lt_s_imm, .branch_le_s_imm, .branch_ge_s_imm, .branch_gt_s_imm => {
                const args = i.args.OneRegOneImmOneOffset;
                const reg = context.registers[args.register_index];
                const imm = args.immediate;
                const should_branch = switch (i.instruction) {
                    .branch_eq_imm => reg == imm,
                    .branch_ne_imm => reg != imm,
                    .branch_lt_u_imm => reg < imm,
                    .branch_le_u_imm => reg <= imm,
                    .branch_ge_u_imm => reg >= imm,
                    .branch_gt_u_imm => reg > imm,
                    .branch_lt_s_imm => @as(i64, @bitCast(reg)) < @as(i64, @bitCast(imm)),
                    .branch_le_s_imm => @as(i64, @bitCast(reg)) <= @as(i64, @bitCast(imm)),
                    .branch_ge_s_imm => @as(i64, @bitCast(reg)) >= @as(i64, @bitCast(imm)),
                    .branch_gt_s_imm => @as(i64, @bitCast(reg)) > @as(i64, @bitCast(imm)),
                    else => unreachable,
                };

                if (should_branch) {
                    context.pc = updatePc(context.pc, args.offset) catch {
                        return .{ .terminal = .panic };
                    };
                    return .cont;
                }
            },

            // A.5.9 Instructions with Arguments of Two Registers
            .move_reg => {
                const args = i.args.TwoReg;
                context.registers[args.first_register_index] = context.registers[args.second_register_index];
            },

            .sbrk => {
                // Memory allocation is handled by the Memory implementation
            },

            // A.5.10 Instructions with Arguments of Two Registers & One Immediate
            .add_imm_32, .add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] +% args.immediate;
                if (i.instruction == .add_imm_32) {
                    context.registers[args.first_register_index] = @as(u32, @truncate(context.registers[args.first_register_index]));
                }
            },

            .mul_imm_32, .mul_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] *% args.immediate;
                if (i.instruction == .mul_imm_32) {
                    context.registers[args.first_register_index] = @as(u32, @truncate(context.registers[args.first_register_index]));
                }
            },

            // A.5.11 Instructions with Arguments of Two Registers & One Offset
            .branch_eq, .branch_ne, .branch_lt_u, .branch_lt_s, .branch_ge_u, .branch_ge_s => {
                const args = i.args.TwoRegOneOffset;
                const reg1 = context.registers[args.first_register_index];
                const reg2 = context.registers[args.second_register_index];
                const should_branch = switch (i.instruction) {
                    .branch_eq => reg1 == reg2,
                    .branch_ne => reg1 != reg2,
                    .branch_lt_u => reg1 < reg2,
                    .branch_lt_s => @as(i64, @bitCast(reg1)) < @as(i64, @bitCast(reg2)),
                    .branch_ge_u => reg1 >= reg2,
                    .branch_ge_s => @as(i64, @bitCast(reg1)) >= @as(i64, @bitCast(reg2)),
                    else => unreachable,
                };
                if (should_branch) {
                    context.pc = updatePc(context.pc, args.offset) catch {
                        return .{ .terminal = .panic };
                    };
                    return .cont;
                }
            },

            // A.5.12 Instructions with Arguments of Two Registers and Two Immediates
            .load_imm_jump_ind => {
                const args = i.args.TwoRegTwoImm;
                context.registers[args.first_register_index] = args.first_immediate;
                const jump_dest = context.program.validateJumpAddress(
                    @truncate(context.registers[args.second_register_index] +% args.second_immediate),
                ) catch |err| {
                    return if (err == error.JumpAddressHalt)
                        .{ .terminal = .{ .halt = &[_]u8{} } }
                    else
                        .{ .terminal = .panic };
                };
                context.pc = jump_dest;
                return .cont;
            },

            // A.5.13 Instructions with Arguments of Three Registers
            .add_32, .add_64 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] +%
                    context.registers[args.second_register_index];
                if (i.instruction == .add_32) {
                    context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                }
            },

            .sub_32, .sub_64 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] -%
                    context.registers[args.second_register_index];
                if (i.instruction == .sub_32) {
                    context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                }
            },

            .mul_32, .mul_64 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] *%
                    context.registers[args.second_register_index];
                if (i.instruction == .mul_32) {
                    context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                }
            },

            .div_u_32, .div_u_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = if (i.instruction == .div_u_32) 0xFFFFFFFF else 0xFFFFFFFFFFFFFFFF;
                } else {
                    context.registers[args.third_register_index] = @divTrunc(context.registers[args.first_register_index], context.registers[args.second_register_index]);
                    if (i.instruction == .div_u_32) {
                        context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                    }
                }
            },

            .div_s_32, .div_s_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = if (i.instruction == .div_s_32) 0xFFFFFFFF else 0xFFFFFFFFFFFFFFFF;
                } else {
                    const is_32 = i.instruction == .div_s_32;
                    const reg1 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.first_register_index]))))
                    else
                        @as(i64, @bitCast(context.registers[args.first_register_index]));
                    const reg2 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.second_register_index]))))
                    else
                        @as(i64, @bitCast(context.registers[args.second_register_index]));
                    context.registers[args.third_register_index] = @bitCast(@divTrunc(reg1, reg2));
                }
            },

            .rem_u_32, .rem_u_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = context.registers[args.first_register_index];
                } else {
                    context.registers[args.third_register_index] = @rem(context.registers[args.first_register_index], context.registers[args.second_register_index]);
                    if (i.instruction == .rem_u_32) {
                        context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                    }
                }
            },

            .rem_s_32, .rem_s_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = context.registers[args.first_register_index];
                } else {
                    const is_32 = i.instruction == .rem_s_32;
                    const reg1 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.first_register_index]))))
                    else
                        @as(i64, @bitCast(context.registers[args.first_register_index]));
                    const reg2 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.second_register_index]))))
                    else
                        @as(i64, @bitCast(context.registers[args.second_register_index]));
                    context.registers[args.third_register_index] = @bitCast(@rem(reg1, reg2));
                }
            },

            .shlo_l_32, .shlo_l_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = if (i.instruction == .shlo_l_32) 0x1F else 0x3F;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] << @intCast(context.registers[args.second_register_index] & mask);
                if (i.instruction == .shlo_l_32) {
                    context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                }
            },

            .shlo_r_32, .shlo_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = if (i.instruction == .shlo_r_32) 0x1F else 0x3F;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] >> @intCast(context.registers[args.second_register_index] & mask);
                if (i.instruction == .shlo_r_32) {
                    context.registers[args.third_register_index] = @as(u32, @truncate(context.registers[args.third_register_index]));
                }
            },

            .shar_r_32, .shar_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = if (i.instruction == .shar_r_32) 0x1F else 0x3F;
                const shift = context.registers[args.second_register_index] & mask;
                if (i.instruction == .shar_r_32) {
                    const value = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.first_register_index]))));
                    context.registers[args.third_register_index] = @as(u32, @bitCast(value >> @intCast(shift)));
                } else {
                    const value = @as(i64, @bitCast(context.registers[args.first_register_index]));
                    context.registers[args.third_register_index] = @bitCast(value >> @intCast(shift));
                }
            },

            .@"and" => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] &
                    context.registers[args.second_register_index];
            },

            .xor => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] ^
                    context.registers[args.second_register_index];
            },

            .@"or" => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] |
                    context.registers[args.second_register_index];
            },

            .mul_upper_s_s => {
                const args = i.args.ThreeReg;
                const result = @as(i128, @intCast(@as(i64, @bitCast(context.registers[args.first_register_index])))) *
                    @as(i128, @intCast(@as(i64, @bitCast(context.registers[args.second_register_index]))));
                context.registers[args.third_register_index] = @as(u64, @bitCast(@as(i64, @intCast(result >> 64))));
            },

            .mul_upper_u_u => {
                const args = i.args.ThreeReg;
                const result = @as(u128, context.registers[args.first_register_index]) *
                    @as(u128, context.registers[args.second_register_index]);
                context.registers[args.third_register_index] = @intCast(result >> 64);
            },

            .mul_upper_s_u => {
                const args = i.args.ThreeReg;
                const result = @as(i128, @intCast(@as(i64, @bitCast(context.registers[args.first_register_index])))) *
                    @as(i128, @intCast(context.registers[args.second_register_index]));
                context.registers[args.third_register_index] = @as(u64, @bitCast(@as(i64, @intCast(result >> 64))));
            },

            .set_lt_u => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    if (context.registers[args.first_register_index] < context.registers[args.second_register_index]) 1 else 0;
            },

            .set_lt_s => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    if (@as(i64, @bitCast(context.registers[args.first_register_index])) <
                    @as(i64, @bitCast(context.registers[args.second_register_index]))) 1 else 0;
            },

            .cmov_iz => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = context.registers[args.first_register_index];
                }
            },

            .cmov_nz => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] != 0) {
                    context.registers[args.third_register_index] = context.registers[args.first_register_index];
                }
            },

            // A.5.10 Instructions with Arguments of Two Registers & One Immediate (continued)
            .store_ind_u8 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                var bytes = [_]u8{@truncate(context.registers[args.first_register_index])};
                context.memory.write(@truncate(addr), &bytes) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };
            },
            .store_ind_u16 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &bytes, @truncate(context.registers[args.first_register_index]), .little);
                context.memory.write(@truncate(addr), &bytes) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };
            },
            .store_ind_u32 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, @truncate(context.registers[args.first_register_index]), .little);
                context.memory.write(@truncate(addr), &bytes) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };
            },
            .store_ind_u64 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, context.registers[args.first_register_index], .little);
                context.memory.write(@truncate(addr), &bytes) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };
            },

            .load_ind_u8, .load_ind_u16, .load_ind_u32, .load_ind_u64 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                const data = context.memory.read(@truncate(addr), switch (i.instruction) {
                    .load_ind_u8 => 1,
                    .load_ind_u16 => 2,
                    .load_ind_u32 => 4,
                    .load_ind_u64 => 8,
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };

                context.registers[args.first_register_index] = switch (i.instruction) {
                    .load_ind_u8 => data[0],
                    .load_ind_u16 => std.mem.readInt(u16, data[0..2], .little),
                    .load_ind_u32 => std.mem.readInt(u32, data[0..4], .little),
                    .load_ind_u64 => std.mem.readInt(u64, data[0..8], .little),
                    else => unreachable,
                };
            },

            .load_ind_i8, .load_ind_i16, .load_ind_i32 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                const data = context.memory.read(@truncate(addr), switch (i.instruction) {
                    .load_ind_i8 => 1,
                    .load_ind_i16 => 2,
                    .load_ind_i32 => 4,
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = @truncate(addr) } };
                    }
                    return err;
                };

                context.registers[args.first_register_index] = switch (i.instruction) {
                    .load_ind_i8 => @bitCast(@as(i64, @intCast(@as(i8, @bitCast(data[0]))))),
                    .load_ind_i16 => @bitCast(@as(i64, @intCast(@as(i16, @bitCast(std.mem.readInt(u16, data[0..2], .little)))))),
                    .load_ind_i32 => @bitCast(@as(i64, @intCast(@as(i32, @bitCast(std.mem.readInt(u32, data[0..4], .little)))))),
                    else => unreachable,
                };
            },

            .and_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] & args.immediate;
            },

            .xor_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] ^ args.immediate;
            },

            .or_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] | args.immediate;
            },

            .set_lt_u_imm, .set_lt_s_imm, .set_gt_u_imm, .set_gt_s_imm => {
                const args = i.args.TwoRegOneImm;
                const result = switch (i.instruction) {
                    .set_lt_u_imm => context.registers[args.second_register_index] < args.immediate,
                    .set_lt_s_imm => @as(i64, @bitCast(context.registers[args.second_register_index])) < @as(i64, @bitCast(args.immediate)),
                    .set_gt_u_imm => context.registers[args.second_register_index] > args.immediate,
                    .set_gt_s_imm => @as(i64, @bitCast(context.registers[args.second_register_index])) > @as(i64, @bitCast(args.immediate)),
                    else => unreachable,
                };
                context.registers[args.first_register_index] = if (result) 1 else 0;
            },

            .shlo_l_imm_32, .shlo_l_imm_64, .shlo_l_imm_alt_32, .shlo_l_imm_alt_64 => {
                const args = i.args.TwoRegOneImm;
                const mask: u64 = switch (i.instruction) {
                    .shlo_l_imm_32, .shlo_l_imm_alt_32 => 0x1F,
                    .shlo_l_imm_64, .shlo_l_imm_alt_64 => 0x3F,
                    else => unreachable,
                };
                const shift = switch (i.instruction) {
                    .shlo_l_imm_32, .shlo_l_imm_64 => args.immediate & mask,
                    .shlo_l_imm_alt_32, .shlo_l_imm_alt_64 => context.registers[args.second_register_index] & mask,
                    else => unreachable,
                };
                const value = switch (i.instruction) {
                    .shlo_l_imm_32, .shlo_l_imm_64 => context.registers[args.second_register_index],
                    .shlo_l_imm_alt_32, .shlo_l_imm_alt_64 => args.immediate,
                    else => unreachable,
                };
                context.registers[args.first_register_index] = value << @intCast(shift);
                if (i.instruction == .shlo_l_imm_32 or i.instruction == .shlo_l_imm_alt_32) {
                    context.registers[args.first_register_index] = @as(u32, @truncate(context.registers[args.first_register_index]));
                }
            },

            .shlo_r_imm_32, .shlo_r_imm_64, .shlo_r_imm_alt_32, .shlo_r_imm_alt_64 => {
                const args = i.args.TwoRegOneImm;
                const mask: u64 = switch (i.instruction) {
                    .shlo_r_imm_32, .shlo_r_imm_alt_32 => 0x1F,
                    .shlo_r_imm_64, .shlo_r_imm_alt_64 => 0x3F,
                    else => unreachable,
                };
                const shift = switch (i.instruction) {
                    .shlo_r_imm_32, .shlo_r_imm_64 => args.immediate & mask,
                    .shlo_r_imm_alt_32, .shlo_r_imm_alt_64 => context.registers[args.second_register_index] & mask,
                    else => unreachable,
                };
                const value = switch (i.instruction) {
                    .shlo_r_imm_32, .shlo_r_imm_64 => context.registers[args.second_register_index],
                    .shlo_r_imm_alt_32, .shlo_r_imm_alt_64 => args.immediate,
                    else => unreachable,
                };
                context.registers[args.first_register_index] = value >> @intCast(shift);
                if (i.instruction == .shlo_r_imm_32 or i.instruction == .shlo_r_imm_alt_32) {
                    context.registers[args.first_register_index] = @as(u32, @truncate(context.registers[args.first_register_index]));
                }
            },

            .shar_r_imm_32, .shar_r_imm_64, .shar_r_imm_alt_32, .shar_r_imm_alt_64 => {
                const args = i.args.TwoRegOneImm;
                const mask: u64 = switch (i.instruction) {
                    .shar_r_imm_32, .shar_r_imm_alt_32 => 0x1F,
                    .shar_r_imm_64, .shar_r_imm_alt_64 => 0x3F,
                    else => unreachable,
                };
                const shift = switch (i.instruction) {
                    .shar_r_imm_32, .shar_r_imm_64 => args.immediate & mask,
                    .shar_r_imm_alt_32, .shar_r_imm_alt_64 => context.registers[args.second_register_index] & mask,
                    else => unreachable,
                };
                const value = switch (i.instruction) {
                    .shar_r_imm_32 => @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.second_register_index])))),
                    .shar_r_imm_64 => @as(i64, @bitCast(context.registers[args.second_register_index])),
                    // FIXME: check this
                    .shar_r_imm_alt_32 => @as(i32, @bitCast(@as(u32, @truncate(args.immediate)))),
                    .shar_r_imm_alt_64 => @as(i64, @bitCast(args.immediate)),
                    else => unreachable,
                };
                context.registers[args.first_register_index] = @bitCast(value >> @intCast(shift));
            },

            .cmov_iz_imm => {
                const args = i.args.TwoRegOneImm;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.first_register_index] = args.immediate;
                }
            },

            .cmov_nz_imm => {
                const args = i.args.TwoRegOneImm;
                if (context.registers[args.second_register_index] != 0) {
                    context.registers[args.first_register_index] = args.immediate;
                }
            },

            .neg_add_imm_32, .neg_add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = args.immediate -% context.registers[args.second_register_index];
                if (i.instruction == .neg_add_imm_32) {
                    context.registers[args.first_register_index] = @as(u32, @truncate(context.registers[args.first_register_index]));
                }
            },
        }

        context.pc += i.skip_l() + 1;
        return .cont;
    }
};
