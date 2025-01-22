const std = @import("std");
const Allocator = std.mem.Allocator;
const Instruction = @import("./pvm/instruction.zig").Instruction;
const Program = @import("./pvm/program.zig").Program;
const Decoder = @import("./pvm/decoder.zig").Decoder;
const Memory = @import("./pvm/memory.zig").Memory;

const HostCallFn = @import("./pvm/host_calls.zig").HostCallFn;

const ExecutionContext = @import("./pvm/execution_context.zig").ExecutionContext;

const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;
const updatePc = @import("./pvm/utils.zig").updatePc;

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

        // Execution related errors
        OutOfGas,
        Trap,
    } || Decoder.Error || Program.Error || error{ OutOfMemory, EmptyBuffer, InsufficientData };

    pub fn executeStep(
        context: *const ExecutionContext,
    ) !ExecutionStepResult {
        // Decode instruction
        const instruction = try context.decoder.decodeInstruction(context.pc);

        // Check gas
        const gas_cost = getInstructionGasCost(instruction);
        if (context.gas < gas_cost) {
            return .{ .terminal = .out_of_gas };
        }
        context.gas -= gas_cost;

        // Execute instruction
        return executeInstruction(context, instruction);
    }

    pub fn execute(
        context: *const ExecutionContext,
    ) !ExecutionResult {
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
    fn executeInstruction(context: *ExecutionContext, i: InstructionWithArgs) !ExecutionStepResult {
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
                const jump_dest = try context.program.validateJumpAddress(@truncate(i.args.OneOffset.offset));
                if (jump_dest == 0xFFFF0000) {
                    // Special halt PC reached
                    return .{ .terminal = .{ .halt = &[_]u8{} } }; // Empty halt output
                }
                context.pc = jump_dest;
                return .cont;
            },

            // A.5.6 Instructions with Arguments of One Register & One Immediate
            .jump_ind => {
                const args = i.args.OneRegOneImm;
                const jump_dest = try context.program.validateJumpAddress(@truncate(context.registers[args.register_index] +| args.immediate));
                if (jump_dest == 0xFFFF0000) {
                    return .{ .terminal = .{ .halt = &[_]u8{} } }; // Empty halt output
                }
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
                    .load_i8 => @as(i64, @intCast(@as(i8, @bitCast(data[0])))),
                    .load_u16 => std.mem.readInt(u16, data[0..2], .little),
                    .load_i16 => @as(i64, @intCast(@as(i16, @bitCast(std.mem.readIntLittle(u16, data[0..2]))))),
                    .load_u32 => std.mem.readInt(u32, data[0..4], .little),
                    .load_i32 => @as(i64, @intCast(@as(i32, @bitCast(std.mem.readIntLittle(u32, data[0..4]))))),
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
                const jump_dest = try context.program.validateJumpAddress(@truncate(args.offset));
                if (jump_dest == 0xFFFF0000) {
                    return .{ .terminal = .{ .halt = &[_]u8{} } }; // Empty halt output
                }
                context.pc = jump_dest;
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
                    const jump_dest = try context.program.validateJumpAddress(@truncate(args.offset));
                    if (jump_dest == 0xFFFF0000) {
                        return .{ .terminal = .{ .halt = &[_]u8{} } }; // Empty halt output
                    }
                    context.pc = jump_dest;
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
                return .cont;
            },

            // A.5.10 Instructions with Arguments of Two Registers & One Immediate
            .add_imm_32, .add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] +% args.immediate;
                if (i.instruction == .add_imm_32) {
                    context.registers[args.first_register_index] = @as(u32, @truncate(context.registers[args.first_register_index]));
                }
            },

            else => {
                std.debug.print("Unimplemented instruction: {s}\n", .{@tagName(i.instruction)});
                return error.UnimplementedInstruction;
            },
        }

        context.pc = i.skip_l() + 1;
    }
};
