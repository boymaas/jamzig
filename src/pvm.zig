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
        UnalignedAddress,
        PageOverlap,

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
                        .page_fault => |addr| {
                            return .{ .err = .{ .page_fault = addr } };
                        },
                    }
                },
                .terminal => |result| switch (result) {
                    .halt => |output| return .{ .halt = output },
                    .panic => return .{ .err = .panic },
                    .out_of_gas => return .{ .err = .out_of_gas },
                    .page_fault => |addr| {
                        // FIXME: to make gas accounting work against test vectors
                        context.gas -= 1;
                        return .{ .err = .{ .page_fault = addr } };
                    },
                },
            }
        }
    }

    fn getInstructionGasCost(inst: InstructionWithArgs) u32 {
        return switch (inst.instruction) {
            else => 1,
        };
    }

    const PcOffset = i32;
    const signExtendToU64 = @import("./pvm/sign_extention.zig").signExtendToU64;
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

                (switch (i.instruction) {
                    .store_imm_u8 => context.memory.writeInt(u8, @truncate(args.first_immediate), @truncate(args.second_immediate)),
                    .store_imm_u16 => context.memory.writeInt(u16, @truncate(args.first_immediate), @truncate(args.second_immediate)),
                    .store_imm_u32 => context.memory.writeInt(u32, @truncate(args.first_immediate), @truncate(args.second_immediate)),
                    .store_imm_u64 => context.memory.writeInt(u64, @truncate(args.first_immediate), args.second_immediate),
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },

            // A.5.5 Instructions with Arguments of One Offset
            .jump => {
                context.pc = updatePc(context.pc, i.args.OneOffset.offset) catch {
                    return .{ .terminal = .panic };
                };
                return .cont;
            },

            // A.5.6 Instructions with Arguments of One Register & One Immediate
            .jump_ind => {
                const args = i.args.OneRegOneImm;
                const jump_dest = context.program.validateJumpAddress(
                    @truncate(context.registers[args.register_index] +% args.immediate),
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
                const addr: u32 = @truncate(args.immediate);
                const memory = &context.memory;

                context.registers[args.register_index] = switch (i.instruction) {
                    .load_u8 => memory.readIntAndSignExtend(u8, addr),
                    .load_i8 => memory.readIntAndSignExtend(i8, addr),
                    .load_u16 => memory.readIntAndSignExtend(u16, addr),
                    .load_i16 => memory.readIntAndSignExtend(i16, addr),
                    .load_u32 => memory.readIntAndSignExtend(u32, addr),
                    .load_i32 => memory.readIntAndSignExtend(i32, addr),
                    .load_u64 => memory.readInt(u64, addr),
                    else => unreachable,
                } catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = memory.last_violation.?.address } };
                    }
                    return err;
                };
            },

            .store_u8, .store_u16, .store_u32, .store_u64 => {
                const args = i.args.OneRegOneImm;

                const value = context.registers[args.register_index];

                (switch (i.instruction) {
                    .store_u8 => context.memory.writeInt(u8, @truncate(args.immediate), @truncate(value)),
                    .store_u16 => context.memory.writeInt(u16, @truncate(args.immediate), @truncate(value)),
                    .store_u32 => context.memory.writeInt(u32, @truncate(args.immediate), @truncate(value)),
                    .store_u64 => context.memory.writeInt(u64, @truncate(args.immediate), value),
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },

            // A.5.7 Instructions with Arguments of One Register & Two Immediates
            .store_imm_ind_u8, .store_imm_ind_u16, .store_imm_ind_u32, .store_imm_ind_u64 => {
                const args = i.args.OneRegTwoImm;

                const addr = context.registers[args.register_index] +% args.first_immediate;

                (switch (i.instruction) {
                    .store_imm_ind_u8 => context.memory.writeInt(u8, @truncate(addr), @truncate(args.second_immediate)),
                    .store_imm_ind_u16 => context.memory.writeInt(u16, @truncate(addr), @truncate(args.second_immediate)),
                    .store_imm_ind_u32 => context.memory.writeInt(u32, @truncate(addr), @truncate(args.second_immediate)),
                    .store_imm_ind_u64 => context.memory.writeInt(u64, @truncate(addr), args.second_immediate),
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
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
                const args = i.args.TwoReg;
                const size = context.registers[args.second_register_index];

                const result = try context.memory.allocate(@truncate(size));

                context.registers[args.first_register_index] = result;
            },

            // Bit counting and manipulation instructions
            .count_set_bits_64 => {
                const args = i.args.TwoReg;
                // Count the 1 bits in register A using Brian Kernighan's algorithm
                context.registers[args.first_register_index] = @popCount(context.registers[args.second_register_index]);
            },

            .count_set_bits_32 => {
                const args = i.args.TwoReg;
                // Count 1 bits in lower 32 bits only
                const value = @as(u32, @truncate(context.registers[args.second_register_index]));
                context.registers[args.first_register_index] = @popCount(value);
            },

            .leading_zero_bits_64 => {
                const args = i.args.TwoReg;
                const value = context.registers[args.second_register_index];
                context.registers[args.first_register_index] =
                    if (value == 0) 64 else @clz(value);
            },

            .leading_zero_bits_32 => {
                const args = i.args.TwoReg;
                const value = @as(u32, @truncate(context.registers[args.second_register_index]));
                context.registers[args.first_register_index] =
                    if (value == 0) 32 else @clz(value);
            },

            .trailing_zero_bits_64 => {
                const args = i.args.TwoReg;
                const value = context.registers[args.second_register_index];
                context.registers[args.first_register_index] =
                    if (value == 0) 64 else @ctz(value);
            },

            .trailing_zero_bits_32 => {
                const args = i.args.TwoReg;
                const value = @as(u32, @truncate(context.registers[args.second_register_index]));
                context.registers[args.first_register_index] =
                    if (value == 0) 32 else @ctz(value);
            },

            .sign_extend_8 => {
                const args = i.args.TwoReg;
                const value = @as(u8, @truncate(context.registers[args.second_register_index]));
                context.registers[args.first_register_index] =
                    @bitCast(@as(i64, @intCast(@as(i8, @bitCast(value)))));
            },

            .sign_extend_16 => {
                const args = i.args.TwoReg;
                const value = @as(u16, @truncate(context.registers[args.second_register_index]));
                context.registers[args.first_register_index] =
                    @bitCast(@as(i64, @intCast(@as(i16, @bitCast(value)))));
            },

            .zero_extend_16 => {
                const args = i.args.TwoReg;
                context.registers[args.first_register_index] =
                    @as(u16, @truncate(context.registers[args.second_register_index]));
            },

            .reverse_bytes => {
                const args = i.args.TwoReg;
                const value = context.registers[args.second_register_index];
                context.registers[args.first_register_index] = @byteSwap(value);
            },

            // A.5.10 Instructions with Arguments of Two Registers & One Immediate
            .store_ind_u8 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                const value: u8 = @truncate(context.registers[args.first_register_index]);
                context.memory.writeInt(u8, @truncate(addr), value) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },
            .store_ind_u16 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                context.memory.writeInt(u16, @truncate(addr), @truncate(context.registers[args.first_register_index])) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },
            .store_ind_u32 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                context.memory.writeInt(u32, @truncate(addr), @truncate(context.registers[args.first_register_index])) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },
            .store_ind_u64 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;
                context.memory.writeInt(u64, @truncate(addr), context.registers[args.first_register_index]) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },

            .load_ind_u8, .load_ind_u16, .load_ind_u32, .load_ind_u64 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;

                context.registers[args.first_register_index] = (switch (i.instruction) {
                    .load_ind_u8 => context.memory.readIntAndSignExtend(u8, @truncate(addr)),
                    .load_ind_u16 => context.memory.readIntAndSignExtend(u16, @truncate(addr)),
                    .load_ind_u32 => context.memory.readIntAndSignExtend(u32, @truncate(addr)),
                    .load_ind_u64 => context.memory.readInt(u64, @truncate(addr)),
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },

            .load_ind_i8, .load_ind_i16, .load_ind_i32 => {
                const args = i.args.TwoRegOneImm;
                const addr = context.registers[args.second_register_index] +% args.immediate;

                context.registers[args.first_register_index] = (switch (i.instruction) {
                    .load_ind_i8 => context.memory.readIntAndSignExtend(i8, @truncate(addr)),
                    .load_ind_i16 => context.memory.readIntAndSignExtend(i16, @truncate(addr)),
                    .load_ind_i32 => context.memory.readIntAndSignExtend(i32, @truncate(addr)),
                    else => unreachable,
                }) catch |err| {
                    if (err == error.PageFault) {
                        return .{ .terminal = .{ .page_fault = context.memory.last_violation.?.address } };
                    }
                    return err;
                };
            },

            .add_imm_32 => {
                const args = i.args.TwoRegOneImm;
                const result = context.registers[args.second_register_index] +% args.immediate;
                context.registers[args.first_register_index] = signExtendToU64(u32, @truncate(result));
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

            .mul_imm_32 => {
                const args = i.args.TwoRegOneImm;
                const result = context.registers[args.second_register_index] *% args.immediate;
                context.registers[args.first_register_index] = @as(u32, @truncate(result));
            },

            .set_lt_u_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] =
                    if (context.registers[args.second_register_index] < args.immediate) 1 else 0;
            },

            .set_lt_s_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] =
                    if (@as(i64, @bitCast(context.registers[args.second_register_index])) <
                    @as(i64, @bitCast(args.immediate))) 1 else 0;
            },

            .shlo_l_imm_32 => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x1F;
                // First truncate input to 32 bits then perform shift on 32-bit value

                //The sequence of operations matters because slliw is specifically
                //designed to maintain 32-bit behavior even on 64-bit machines. Any
                //intermediate overflow should happen at the 32-bit level before
                //sign extension.
                const input = @as(u32, @truncate(context.registers[args.second_register_index]));
                const shifted = input << @intCast(shift);
                context.registers[args.first_register_index] = signExtendToU64(u32, shifted);
            },

            .shlo_r_imm_32 => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x1F;
                const input = @as(u32, @truncate(context.registers[args.second_register_index]));
                const shifted = input >> @intCast(shift);
                context.registers[args.first_register_index] = signExtendToU64(u32, shifted);
            },

            .shar_r_imm_32 => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x1F;
                const input = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.second_register_index]))));
                const shifted = input >> @intCast(shift);
                context.registers[args.first_register_index] = signExtendToU64(i32, shifted);
            },

            .neg_add_imm_32 => {
                const args = i.args.TwoRegOneImm;
                const result = signExtendToU64(
                    u32,
                    // doing a normal wrapping substraction, letting zig take care of the details
                    @as(u32, @truncate((args.immediate -% context.registers[args.second_register_index]))),
                );
                context.registers[args.first_register_index] = result;
            },

            .set_gt_u_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] =
                    if (context.registers[args.second_register_index] > args.immediate) 1 else 0;
            },
            .set_gt_s_imm => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] =
                    if (@as(i64, @bitCast(context.registers[args.second_register_index])) >
                    @as(i64, @bitCast(args.immediate))) 1 else 0;
            },

            .shlo_l_imm_alt_32 => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x1F;
                const result = args.immediate << @intCast(shift);
                context.registers[args.first_register_index] = result;
            },
            .shlo_r_imm_alt_32 => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x1F;
                const input = @as(u32, @truncate(args.immediate));
                const shifted = input >> @intCast(shift);
                context.registers[args.first_register_index] = signExtendToU64(u32, shifted);
            },
            .shar_r_imm_alt_32 => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x1F;
                // First truncate and convert to signed 32-bit
                const input = @as(i32, @bitCast(@as(u32, @truncate(args.immediate))));
                // Perform arithmetic shift at 32-bit level
                const shifted = input >> @intCast(shift);
                // Sign extend result back to 64 bits
                context.registers[args.first_register_index] = signExtendToU64(i32, shifted);
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
            .add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] +% args.immediate;
            },
            .mul_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] *% args.immediate;
            },
            .shlo_l_imm_64 => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x3F;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] << @intCast(shift);
            },
            .shlo_r_imm_64 => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x3F;
                context.registers[args.first_register_index] = context.registers[args.second_register_index] >> @intCast(shift);
            },
            .shar_r_imm_64 => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x3F;
                const value = @as(i64, @bitCast(context.registers[args.second_register_index]));
                context.registers[args.first_register_index] = @bitCast(value >> @intCast(shift));
            },
            .neg_add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                context.registers[args.first_register_index] = args.immediate -% context.registers[args.second_register_index];
            },
            .shlo_l_imm_alt_64 => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x3F;
                context.registers[args.first_register_index] = args.immediate << @intCast(shift);
            },
            .shlo_r_imm_alt_64 => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x3F;
                context.registers[args.first_register_index] = args.immediate >> @intCast(shift);
            },
            .shar_r_imm_alt_64 => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x3F;
                const value = @as(i64, @bitCast(args.immediate));
                context.registers[args.first_register_index] = @bitCast(value >> @intCast(shift));
            },
            .rot_r_64_imm => {
                const args = i.args.TwoRegOneImm;
                // Rotate right by immediate value for 64-bit
                // Mask shift value to 6 bits (0-63) as per spec
                const shift = args.immediate & 0x3F;
                // Rotate right using std.math.rotr
                context.registers[args.first_register_index] = std.math.rotr(
                    u64,
                    context.registers[args.second_register_index],
                    shift,
                );
            },
            .rot_r_64_imm_alt => {
                const args = i.args.TwoRegOneImm;
                // Alternate version where rotate amount comes from register
                // Mask shift value to 6 bits (0-63)
                const shift = context.registers[args.second_register_index] & 0x3F;
                // Rotate immediate value right
                context.registers[args.first_register_index] = std.math.rotr(u64, args.immediate, shift);
            },
            .rot_r_32_imm => {
                const args = i.args.TwoRegOneImm;
                // Rotate right by immediate for 32-bit value
                // Mask shift value to 5 bits (0-31)
                const shift = args.immediate & 0x1F;
                // Extract 32-bit value from register
                const value = @as(u32, @truncate(context.registers[args.second_register_index]));
                // Perform rotation
                const result = std.math.rotr(u32, value, shift);
                // Sign extend result back to 64 bits
                context.registers[args.first_register_index] = signExtendToU64(u32, result);
            },
            .rot_r_32_imm_alt => {
                const args = i.args.TwoRegOneImm;
                // Alternate version where rotate amount comes from register
                // Mask shift value to 5 bits (0-31)
                const shift = context.registers[args.second_register_index] & 0x1F;
                // Extract 32-bit value from immediate
                const value = @as(u32, @truncate(args.immediate));
                // Perform rotation
                const result = std.math.rotr(u32, value, shift);
                // Sign extend result back to 64 bits
                context.registers[args.first_register_index] = signExtendToU64(u32, result);
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

                // Defer register update until after jump validation
                defer context.registers[args.first_register_index] = args.first_immediate;
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
            .add_32 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] = signExtendToU64(
                    u32,
                    @truncate(context.registers[args.first_register_index] +%
                        context.registers[args.second_register_index]),
                );
            },
            .sub_32 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] = signExtendToU64(
                    u32,
                    @truncate(context.registers[args.first_register_index] -%
                        context.registers[args.second_register_index]),
                );
            },

            .mul_32 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] = signExtendToU64(u32, @truncate(context.registers[args.first_register_index] *%
                    context.registers[args.second_register_index]));
            },

            .div_u_32 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = 0xFFFFFFFFFFFFFFFF;
                } else {
                    context.registers[args.third_register_index] = signExtendToU64(u32, @divTrunc(
                        @as(u32, @truncate(context.registers[args.first_register_index])),
                        @as(u32, @truncate(context.registers[args.second_register_index])),
                    ));
                }
            },

            .div_s_32 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = 0xFFFFFFFFFFFFFFFF;
                } else {
                    const rega = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.first_register_index]))));
                    const regb = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.second_register_index]))));
                    if (rega == std.math.minInt(i32) and regb == -1) {
                        context.registers[args.third_register_index] = signExtendToU64(i32, rega);
                    } else {
                        context.registers[args.third_register_index] = signExtendToU64(i32, @divTrunc(rega, regb));
                    }
                }
            },

            .rem_u_32 => {
                const args = i.args.ThreeReg;
                const rega = @as(u32, @truncate(context.registers[args.first_register_index]));
                const regb = @as(u32, @truncate(context.registers[args.second_register_index]));

                if (regb == 0) {
                    context.registers[args.third_register_index] = signExtendToU64(u32, rega);
                } else {
                    context.registers[args.third_register_index] = signExtendToU64(u32, @mod(rega, regb));
                }
            },

            .rem_s_32 => {
                const args = i.args.ThreeReg;
                const rega: i32 = @bitCast(@as(u32, @truncate(context.registers[args.first_register_index])));
                const regb: i32 = @bitCast(@as(u32, @truncate(context.registers[args.second_register_index])));
                if (regb == 0) {
                    context.registers[args.third_register_index] = signExtendToU64(i32, rega);
                } else if (rega == std.math.minInt(i32) and regb == -1) {
                    context.registers[args.third_register_index] = 0;
                } else {
                    context.registers[args.third_register_index] = signExtendToU64(i32, @rem(rega, regb));
                }
            },

            .shlo_l_32 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x1F;
                const shift = context.registers[args.second_register_index] & mask;
                const result = context.registers[args.first_register_index] << @intCast(shift);
                context.registers[args.third_register_index] = signExtendToU64(u32, @truncate(result));
            },

            .shlo_r_32 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x1F;
                const shift = context.registers[args.second_register_index] & mask;
                const input = @as(u32, @truncate(context.registers[args.first_register_index]));
                const shifted = input >> @intCast(shift);
                context.registers[args.third_register_index] = signExtendToU64(u32, shifted);
            },

            .shar_r_32 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x1F;
                const shift = context.registers[args.second_register_index] & mask;
                const input = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.first_register_index]))));
                const shifted = input >> @intCast(shift);
                context.registers[args.third_register_index] = signExtendToU64(i32, shifted);
            },

            // 64 bit variants

            .add_64 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] +%
                    context.registers[args.second_register_index];
            },
            .sub_64 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] -%
                    context.registers[args.second_register_index];
            },
            .mul_64 => {
                const args = i.args.ThreeReg;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] *%
                    context.registers[args.second_register_index];
            },
            .div_u_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = 0xFFFFFFFFFFFFFFFF;
                } else {
                    context.registers[args.third_register_index] = @divTrunc(context.registers[args.first_register_index], context.registers[args.second_register_index]);
                }
            },
            .div_s_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = 0xFFFFFFFFFFFFFFFF;
                } else {
                    const rega = @as(i64, @bitCast(context.registers[args.first_register_index]));
                    const regb = @as(i64, @bitCast(context.registers[args.second_register_index]));

                    // Check for the special overflow case
                    if (rega == -0x8000000000000000 and regb == -1) {
                        context.registers[args.third_register_index] = context.registers[args.first_register_index];
                    } else {
                        context.registers[args.third_register_index] = @bitCast(@divTrunc(rega, regb));
                    }
                }
            },
            .rem_u_64 => {
                const args = i.args.ThreeReg;
                if (context.registers[args.second_register_index] == 0) {
                    context.registers[args.third_register_index] = context.registers[args.first_register_index];
                } else {
                    context.registers[args.third_register_index] = @mod(context.registers[args.first_register_index], context.registers[args.second_register_index]);
                }
            },
            .rem_s_64 => {
                const args = i.args.ThreeReg;
                const rega: i64 = @bitCast(context.registers[args.first_register_index]);
                const regb: i64 = @bitCast(context.registers[args.second_register_index]);
                if (regb == 0) {
                    context.registers[args.third_register_index] = context.registers[args.first_register_index];
                } else if (rega == std.math.minInt(i64) and regb == -1) {
                    context.registers[args.third_register_index] = 0;
                } else {
                    context.registers[args.third_register_index] = @bitCast(@rem(rega, regb));
                }
            },
            .shlo_l_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x3F;
                const shift = context.registers[args.second_register_index] & mask;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] << @intCast(shift);
            },
            .shlo_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x3F;
                const shift = context.registers[args.second_register_index] & mask;
                context.registers[args.third_register_index] =
                    context.registers[args.first_register_index] >> @intCast(shift);
            },
            .shar_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x3F;
                const shift = context.registers[args.second_register_index] & mask;
                const value = @as(i64, @bitCast(context.registers[args.first_register_index]));
                context.registers[args.third_register_index] = @bitCast(value >> @intCast(shift));
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
            .rot_l_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x3F; // 6 bits for 64-bit rotations
                const shift = context.registers[args.second_register_index] & mask;
                const value = context.registers[args.first_register_index];
                context.registers[args.third_register_index] = std.math.rotl(u64, value, shift);
            },

            .rot_l_32 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x1F; // 5 bits for 32-bit rotations
                const shift = context.registers[args.second_register_index] & mask;
                const value = @as(u32, @truncate(context.registers[args.first_register_index]));
                const result = std.math.rotl(u32, value, shift);
                context.registers[args.third_register_index] = signExtendToU64(u32, result);
            },
            .rot_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x3F;
                const shift = context.registers[args.second_register_index] & mask;
                const value = context.registers[args.first_register_index];
                context.registers[args.third_register_index] = std.math.rotr(u64, value, shift);
            },

            .rot_r_32 => {
                const args = i.args.ThreeReg;
                const mask: u64 = 0x1F; // 5 bits for 32-bit rotations
                const shift = context.registers[args.second_register_index] & mask;
                const value = @as(u32, @truncate(context.registers[args.first_register_index]));
                const result = std.math.rotr(u32, value, shift);
                context.registers[args.third_register_index] = signExtendToU64(u32, result);
            },

            // Bitwise operations with inverted operands
            .and_inv => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = ~context.registers[args.second_register_index]; // Invert second operand
                context.registers[args.third_register_index] = value_a & value_b;
            },

            .or_inv => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = ~context.registers[args.second_register_index]; // Invert second operand
                context.registers[args.third_register_index] = value_a | value_b;
            },

            .xnor => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = context.registers[args.second_register_index];
                context.registers[args.third_register_index] = ~(value_a ^ value_b); // XNOR is inverse of XOR
            },

            .max => {
                const args = i.args.ThreeReg;
                const value_a = @as(i64, @bitCast(context.registers[args.first_register_index]));
                const value_b = @as(i64, @bitCast(context.registers[args.second_register_index]));
                context.registers[args.third_register_index] = @bitCast(@max(value_a, value_b));
            },
            .max_u => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = context.registers[args.second_register_index];
                context.registers[args.third_register_index] = @max(value_a, value_b);
            },

            .min => {
                const args = i.args.ThreeReg;
                const value_a = @as(i64, @bitCast(context.registers[args.first_register_index]));
                const value_b = @as(i64, @bitCast(context.registers[args.second_register_index]));
                context.registers[args.third_register_index] = @bitCast(@min(value_a, value_b));
            },
            .min_u => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = context.registers[args.second_register_index];
                context.registers[args.third_register_index] = @min(value_a, value_b);
            },
        }

        context.pc += i.skip_l() + 1;
        return .cont;
    }
};
