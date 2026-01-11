const std = @import("std");
const Allocator = std.mem.Allocator;

const trace = @import("tracing").scoped(.pvm);

pub const invoke = @import("pvm/invocation.zig");

pub const PVM = struct {
    pub const Program = @import("./pvm/program.zig").Program;
    pub const Decoder = @import("./pvm/decoder.zig").Decoder;

    pub const Instruction = @import("./pvm/instruction.zig").Instruction;
    pub const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;

    pub const Memory = @import("./pvm/memory.zig").Memory;

    pub const HostCallMap = ExecutionContext.HostCallMap;
    pub const HostCallFn = ExecutionContext.HostCallFn;
    pub const HostCallResult = ExecutionContext.HostCallResult;

    pub const ExecutionContext = @import("./pvm/execution_context.zig").ExecutionContext;

    /// Configuration for host calls including an optional catchall handler
    pub const HostCallsConfig = struct {
        /// Map of host call IDs to their implementations
        map: HostCallMap,
        /// Optional catchall handler for non-existent host calls
        catchall: ?HostCallFn = null,
        /// Optional wrapper that intercepts all host calls for error handling
        /// The wrapper receives the host call ID, function, execution context, and host context
        wrapper: ?*const fn (u32, HostCallFn, *ExecutionContext, *anyopaque) HostCallResult = null,
    };

    fn logMemoryWrite(context: *ExecutionContext, addr: u32, value: u64, size: usize) void {
        context.exec_trace.logMemoryWrite(addr, value, size);
    }

    pub const HostCallInvocation = struct {
        /// Host call index
        idx: u32,
        /// Next PC after host call
        next_pc: u32,
    };

    pub const InvocationException = union(enum) {
        halt, // ∎ Regular halt
        panic, // ☇ Panic
        out_of_gas, // ∞ Out of gas
        page_fault: u32, // F Page fault

        pub fn isError(self: @This()) bool {
            return self != .halt;
        }
    };

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

    pub const SingleStepResult = union(enum) {
        // Continue execution with next instruction
        cont: void,
        // Need to execute host call
        host_call: HostCallInvocation,
        // Terminal conditions from graypaper
        terminal: InvocationException,

        pub fn isTerminal(self: *const @This()) bool {
            return self.* == .terminal;
        }
    };

    // Single step invocation
    pub fn singleStepInvocation(context: *ExecutionContext) Error!SingleStepResult {
        const span = trace.span(@src(), .execute_step);
        defer span.deinit();

        const pc_before = context.pc;
        const gas_before = context.gas;

        // Decode instruction
        const instruction = try context.decoder.decodeInstruction(context.pc);
        span.debug("Executing instruction at PC: 0x{d:0>8}: {}", .{ context.pc, instruction });

        // Check gas
        const gas_cost = getInstructionGasCost(instruction);
        context.gas -= gas_cost;

        span.trace("Instruction gas cost: {d}", .{gas_cost});

        // Execute instruction (no per-instruction gas charge)
        const result = executeInstruction(context, instruction);

        // After execute instruction, check if gas went negative
        if (context.gas < 0) {
            span.debug("Out of gas - remaining: {d}", .{context.gas});
            return .{ .terminal = .out_of_gas };
        }

        // Log execution step for trace
        context.exec_trace.logStepAuto(pc_before, gas_before, context.gas, &instruction, &context.registers);

        return result;
    }

    pub const BasicInvocationResult = union(enum) {
        host_call: HostCallInvocation,
        terminal: InvocationException,

        pub fn isError(self: @This()) bool {
            return self == .terminal and self.terminal.isError();
        }
    };

    /// Basic invocation (Basic & Hostcall in one)
    /// Calls singleStepInvocation until we reach a terminal condition/hostcall
    /// or we run out of gas
    pub fn basicInvocation(
        context: *ExecutionContext,
    ) Error!BasicInvocationResult {
        const span = trace.span(@src(), .basic_invocation);
        defer span.deinit();
        while (true) {
            const step_result = try singleStepInvocation(context);

            switch (step_result) {
                .cont => continue,
                .host_call => |invocation| {
                    return .{ .host_call = invocation };
                },
                .terminal => |result| switch (result) {
                    .page_fault => |addr| {
                        return .{ .terminal = .{ .page_fault = addr } };
                    },
                    else => {
                        return .{ .terminal = result };
                    },
                },
            }
        }
    }

    pub const HostCallInvocationResult = union(enum) {
        terminal: InvocationException,

        pub fn isError(self: @This()) bool {
            return self == .terminal and self.terminal.isError();
        }
    };

    // Host call invocation invocation
    pub fn hostcallInvocation(context: *ExecutionContext, call_ctx: *anyopaque) Error!HostCallInvocationResult {
        // iterative host call invocation loop
        while (true) {
            switch (try basicInvocation(context)) {
                .host_call => |params| {
                    const span = trace.span(@src(), .host_call_invocation);
                    defer span.deinit();

                    if (context.host_calls) |host_calls_ptr| {
                        // Cast the anyopaque pointer to our HostCallsConfig
                        const host_calls_config = @as(*const HostCallsConfig, @ptrCast(@alignCast(host_calls_ptr)));

                        const maybe_host_call_fn: ?HostCallFn = host_calls_config.map.get(params.idx) orelse host_calls_config.catchall;
                        if (maybe_host_call_fn) |host_call_fn| {
                            const gas_before = context.gas;
                            const pc_before = context.pc;
                            const registers_before = context.registers;

                            const result = blk: {
                                // Use wrapper if configured, otherwise panic on errors
                                if (host_calls_config.wrapper) |wrapper| {
                                    // Wrapper handles all error processing and logging
                                    break :blk wrapper(params.idx, host_call_fn, context, call_ctx);
                                } else {
                                    // No wrapper - any error should panic to decouple PVM from implementation details
                                    break :blk host_call_fn(context, call_ctx) catch {
                                        return .{ .terminal = .panic };
                                    };
                                }
                            };

                            // Log the host call with comprehensive information
                            context.exec_trace.logHostCall(
                                params.idx,
                                gas_before,
                                context.gas,
                                &registers_before,
                                &context.registers,
                                pc_before,
                                params.next_pc,
                            );

                            switch (result) {
                                .play => {
                                    // Check for out of gas immediately after host call
                                    if (context.gas < 0) {
                                        return .{ .terminal = .out_of_gas };
                                    }

                                    // Update total gas used
                                    context.exec_trace.total_gas_used += gas_before - context.gas;
                                    context.pc = params.next_pc;
                                    continue;
                                },
                                .terminal => |terminal_result| {
                                    return .{
                                        .terminal = terminal_result,
                                    };
                                },
                            }
                        } else {
                            // No catchall provided - return panic as no handler exists
                            span.warn("No host calls catchall provided - return panic", .{});
                            return .{ .terminal = .panic };
                        }
                    } else {
                        span.warn("No host calls configured at all - return panic", .{});
                        return .{ .terminal = .panic };
                    }
                },
                .terminal => |terminal| {
                    return .{ .terminal = terminal };
                },
            }
        }
    }

    // Machine Invocation
    pub const MachineInvocationResult = union(enum) {
        halt: []const u8,
        terminal: union(enum) {
            panic,
            out_of_gas,
        },

        pub fn isSuccess(self: @This()) bool {
            return self == .halt;
        }

        pub fn isError(self: @This()) bool {
            return self == .terminal;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .halt => |result| allocator.free(result),
                .terminal => {}, // No allocated memory to free
            }
            self.* = undefined;
        }
    };

    pub fn machineInvocation(allocator: std.mem.Allocator, exec_ctx: *ExecutionContext, call_ctx: *anyopaque) Error!MachineInvocationResult {
        switch (try hostcallInvocation(exec_ctx, call_ctx)) {
            .terminal => |terminal| {
                switch (terminal) {
                    .halt => {
                        // if memory range in valid memory
                        // read the memory range and return it
                        var return_value = exec_ctx.readSliceBetweenRegister7AndRegister8();
                        defer return_value.deinit();

                        // TODO: this return value could be referencing memory in a page
                        // or could already be copied as it would be on a memory boundary
                        // so we could add a takeOwned which would only dupe if necessary.

                        return .{ .halt = try allocator.dupe(u8, return_value.buffer) };
                    },
                    .out_of_gas => {
                        return .{ .terminal = .out_of_gas };
                    },
                    else => {
                        return .{ .terminal = .panic };
                    },
                }
            },
        }
    }

    fn getInstructionGasCost(_: InstructionWithArgs) u32 {
        // return switch (inst.instruction) {
        //     // .jump => 3,
        //     else => 1,
        // };
        return 1;
    }

    const PcOffset = i32;
    const signExtendToU64 = @import("./pvm/sign_extension.zig").signExtendToU64;
    fn executeInstruction(context: *ExecutionContext, i: InstructionWithArgs) Error!SingleStepResult {
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
                const addr = @as(u32, @truncate(args.first_immediate));
                const value = args.second_immediate;
                const size = switch (i.instruction) {
                    .store_imm_u8 => @as(usize, 1),
                    .store_imm_u16 => @as(usize, 2),
                    .store_imm_u32 => @as(usize, 4),
                    .store_imm_u64 => @as(usize, 8),
                    else => unreachable,
                };

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

                // Log memory write
                logMemoryWrite(context, addr, value, size);
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
                        .{ .terminal = .halt }
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

                // Call the graypaper-compliant sbrk implementation
                const result = context.memory.sbrk(@truncate(size)) catch |err| {
                    return err;
                };

                context.registers[args.first_register_index] = result;
            },

            // Bit counting and manipulation instructions
            .count_set_bits_64 => {
                const args = i.args.TwoReg;
                context.registers[args.first_register_index] = @popCount(context.registers[args.second_register_index]);
            },

            .count_set_bits_32 => {
                const args = i.args.TwoReg;
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
                context.registers[args.first_register_index] = signExtendToU64(u16, value);
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
                context.registers[args.first_register_index] = signExtendToU64(u32, @truncate(result));
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
                // Intermediate overflow must happen at 32-bit level before sign extension
                // to maintain slliw behavior on 64-bit machines
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
                const result = @as(u32, @truncate(args.immediate)) << @intCast(shift);
                context.registers[args.first_register_index] = signExtendToU64(u32, result);
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
                const input = @as(i32, @bitCast(@as(u32, @truncate(args.immediate))));
                const shifted = input >> @intCast(shift);
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
                const shift = args.immediate & 0x3F;
                context.registers[args.first_register_index] = std.math.rotr(
                    u64,
                    context.registers[args.second_register_index],
                    shift,
                );
            },
            .rot_r_64_imm_alt => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x3F;
                context.registers[args.first_register_index] = std.math.rotr(u64, args.immediate, shift);
            },
            .rot_r_32_imm => {
                const args = i.args.TwoRegOneImm;
                const shift = args.immediate & 0x1F;
                const value = @as(u32, @truncate(context.registers[args.second_register_index]));
                const result = std.math.rotr(u32, value, shift);
                context.registers[args.first_register_index] = signExtendToU64(u32, result);
            },
            .rot_r_32_imm_alt => {
                const args = i.args.TwoRegOneImm;
                const shift = context.registers[args.second_register_index] & 0x1F;
                const value = @as(u32, @truncate(args.immediate));
                const result = std.math.rotr(u32, value, shift);
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

                defer context.registers[args.first_register_index] = args.first_immediate;
                const jump_dest = context.program.validateJumpAddress(
                    @truncate(context.registers[args.second_register_index] +% args.second_immediate),
                ) catch |err| {
                    return if (err == error.JumpAddressHalt)
                        .{ .terminal = .halt }
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
                const rega = @as(u32, @truncate(context.registers[args.first_register_index]));
                const regb = @as(u32, @truncate(context.registers[args.second_register_index]));
                if (regb == 0) {
                    context.registers[args.third_register_index] = 0xFFFFFFFFFFFFFFFF;
                } else {
                    context.registers[args.third_register_index] = signExtendToU64(u32, @divTrunc(rega, regb));
                }
            },

            .div_s_32 => {
                const args = i.args.ThreeReg;
                const rega = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.first_register_index]))));
                const regb = @as(i32, @bitCast(@as(u32, @truncate(context.registers[args.second_register_index]))));

                if (regb == 0) {
                    context.registers[args.third_register_index] = 0xFFFFFFFFFFFFFFFF;
                } else {
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
                    context.registers[args.third_register_index] = signExtendToU64(u32, @rem(rega, regb));
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
                const value_b = ~context.registers[args.second_register_index];
                context.registers[args.third_register_index] = value_a & value_b;
            },

            .or_inv => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = ~context.registers[args.second_register_index];
                context.registers[args.third_register_index] = value_a | value_b;
            },

            .xnor => {
                const args = i.args.ThreeReg;
                const value_a = context.registers[args.first_register_index];
                const value_b = context.registers[args.second_register_index];
                context.registers[args.third_register_index] = ~(value_a ^ value_b);
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
