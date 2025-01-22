const std = @import("std");
const Allocator = std.mem.Allocator;
const Instruction = @import("./pvm/instruction.zig").Instruction;
const Program = @import("./pvm/program.zig").Program;
const Decoder = @import("./pvm/decoder.zig").Decoder;
const InstructionWithArgs = @import("./pvm/decoder.zig").InstructionWithArgs;
const updatePc = @import("./pvm/utils.zig").updatePc;

const trace = @import("tracing.zig").scoped(.pvm);

pub const PVM = struct {
    allocator: Allocator,
    program: Program,
    decoder: Decoder,
    registers: [13]u64,
    pc: u32,
    page_map: []PageMap,
    gas: i64,
    error_data: ?ErrorData,
    host_call_map: std.AutoHashMap(u32, *const HostCallFn),

    // Memory layout constants as defined in graypaper A.7
    pub const Z_Z: u32 = 0x10000; // 2^16 = 65,536 - Major zone size
    pub const Z_P: u32 = 0x1000; // 2^12 = 4,096 - Page size
    pub const Z_I: u32 = 0x1000000; // 2^24 - Standard input data size

    // Register indices for better code readability
    pub const REG = struct {
        pub const zero: u8 = 0; // Always zero
        pub const ra: u8 = 1; // Return address
        pub const sp: u8 = 2; // Stack pointer
        pub const gp: u8 = 3; // Global pointer
        pub const tp: u8 = 4; // Thread pointer
        pub const t0: u8 = 5; // Temporary 0
        pub const t1: u8 = 6; // Temporary 1
        pub const InputDataBase: u8 = 7; // Input data base
        pub const InputDataLength: u8 = 8; // Input data length
        pub const s1: u8 = 9; // Saved 1
        pub const a0: u8 = 10; // Argument 0
        pub const a1: u8 = 11; // Argument 1
        pub const a2: u8 = 12; // Argument 2
    };

    pub const ErrorData = union(enum) {
        // when a page fault occurs we whould return the lowest address which caused the fault
        page_fault: u32,
        host_call: u32,
    };

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

    pub const HostCallResult = union(enum) {
        play,
        page_fault: u32,
    };

    const HostCallFn = fn (*i64, *[13]u64, []PVM.PageMap) HostCallResult;

    pub fn hostCall(self: *PVM, host_call_idx: u32) Error!void {
        const span = trace.span(.host_call);
        defer span.deinit();
        span.debug("Executing host call {d}", .{host_call_idx});

        if (self.host_call_map.get(host_call_idx)) |host_func| {
            var gas_c = self.gas;
            var registers_c = self.registers;
            const page_map_c = try self.clonePageMap();

            span.trace("Host call state - Gas: {d}, Registers: {any}", .{ gas_c, registers_c });

            switch (host_func(&gas_c, &registers_c, page_map_c)) {
                .play => {
                    span.debug("Host call completed successfully", .{});
                },
                .page_fault => |address| {
                    span.err("Host call resulted in page fault at address 0x{X:0>8}", .{address});
                    self.freePageMap(page_map_c);
                    self.error_data = .{ .page_fault = address };
                    return Error.MemoryPageFault;
                },
            }

            // Update state after successful host call
            self.gas = gas_c;
            self.registers = registers_c;
            self.freePageMap(self.page_map);
            self.page_map = page_map_c;

            span.trace("Updated state - Gas: {d}, Registers: {any}", .{ self.gas, self.registers });
        } else {
            span.err("Non-existent host call index: {d}", .{host_call_idx});
            return Error.NonExistentHostCall;
        }
    }

    pub fn registerHostCall(self: *PVM, host_call_idx: u32, host_func: HostCallFn) !void {
        const span = trace.span(.register_host_call);
        defer span.deinit();

        try self.host_call_map.put(host_call_idx, host_func);
        span.debug("Registered host call handler for index {d}", .{host_call_idx});
    }

    pub const PageMap = struct {
        address: u32,
        length: u32,
        is_writable: bool,
        data: []u8,
    };

    pub const PageMapConfig = struct {
        address: u32,
        length: u32,
        is_writable: bool,
    };

    pub const MemoryChunk = struct {
        address: u32,
        contents: []u8,
    };

    /// Represents the possible completion states of PVM execution as defined in the graypaper section 4.6
    pub const Status = union(enum) {
        const PageFault = struct {
            /// The address that caused the fault
            address: u32,
        };

        const HostCall = struct {
            /// The idx of the hostcall
            id: u32,
        };

        /// Regular program termination (∎) caused by explicit halt instruction
        halt: void,

        /// Irregular program termination (☇) due to exceptional circumstances
        panic: void,

        /// Gas exhaustion (∞) when running out of allocated gas
        out_of_gas: void,

        /// Page fault (F) when attempting to access inaccessible memory
        page_fault: PageFault,

        /// Host call invocation (̵h) for system call processing
        host_call: HostCall,

        /// Returns true if this is a successful termination state (halt)
        pub fn isSuccess(self: Status) bool {
            return self == .halt;
        }

        /// Returns true if this is a terminal state that cannot be resumed
        pub fn isTerminal(self: Status) bool {
            return switch (self) {
                .halt, .panic, .out_of_gas => true,
                .page_fault, .host_call => false,
            };
        }

        pub fn fromResult(result: PVM.Error!void, error_data: ?ErrorData) Status {
            // If result is null, execution was successful (no error)
            if (result) {
                return Status{ .halt = {} };
            } else |err| {
                // Handle different error cases
                return switch (err) {
                    // Explicit halt condition from djump
                    Error.JumpAddressHalt => .{ .halt = {} },

                    // Memory-related errors map to page fault
                    Error.MemoryPageFault, Error.MemoryAccessOutOfBounds, Error.MemoryWriteProtected => .{
                        .page_fault = .{
                            // Get the address from PVM's error_data
                            .address = error_data.?.page_fault,
                        },
                    },

                    // Gas exhaustion
                    Error.OutOfGas => .{ .out_of_gas = {} },

                    // Host call related
                    Error.NonExistentHostCall => .{
                        .host_call = .{
                            .id = error_data.?.host_call,
                        },
                    },

                    // All other errors map to panic
                    else => .{ .panic = {} },
                };
            }
        }
    };

    pub fn init(allocator: Allocator, raw_program: []const u8, initial_gas: i64) Error!PVM {
        const span = trace.span(.init);
        defer span.deinit();

        span.debug("Initializing PVM with {d} bytes of program data, {d} initial gas", .{ raw_program.len, initial_gas });

        const program = try Program.decode(allocator, raw_program);
        span.debug("Program decoded - code size: {d}, mask size: {d}", .{ program.code.len, program.mask.len });

        span.trace("\n{s}", .{program});

        // Initialize PVM instance with zeroed registers first
        var pvm = PVM{
            .allocator = allocator,
            .program = program,
            .error_data = null,
            .decoder = Decoder.init(program.code, program.mask),
            .registers = [_]u64{0} ** 13,
            .pc = 0,
            .page_map = &[_]PageMap{},
            .gas = initial_gas,
            .host_call_map = std.AutoHashMap(u32, *const HostCallFn).init(allocator),
        };

        pvm.initializeRegisters();

        return pvm;
    }

    /// Initialize registers according to graypaper equation A.37
    fn initializeRegisters(self: *PVM) void {
        const span = trace.span(.init_registers);
        defer span.deinit();

        span.debug("Initializing registers according to graypaper A.37", .{});

        // r0 (zero) = 0xFFFF0000 - 0x10000 = 0xFFFE0000
        self.registers[REG.zero] = 0xFFFE0000;

        // r1 (ra) = 0xFFFFFFFF - 2*Z_Z - Z_I
        self.registers[REG.ra] = 0xFFFFFFFF - (2 * Z_Z) - Z_I;

        // r2-r6 = 0 (already initialized to 0)
        // This includes sp, gp, tp, t0, t1

        // r7 (t2) = 0xFFFFFFFF - Z_Z - Z_I (input data base)
        self.registers[REG.t2] = 0xFFFFFFFF - Z_Z - Z_I;

        // r8 (s0) will be set to input data length when setPageMap is called
        // r9-r12 = 0 (already initialized to 0)

        span.trace("Register initialization complete: {any}", .{self.registers});
    }

    pub fn deinit(self: *PVM) void {
        const span = trace.span(.deinit);
        defer span.deinit();

        span.debug("Cleaning up PVM resources", .{});

        self.program.deinit(self.allocator);
        for (self.page_map) |page| {
            self.allocator.free(page.data);
        }
        self.allocator.free(self.page_map);
        self.host_call_map.deinit();
        self.* = undefined;
    }
    /// 0x00000000 -> [Empty Zone 1     ] (size: Z_Z)
    /// 0x00010000 -> [Code Section     ] (size: code_size)
    ///             -> [Empty Zone 2     ] (size: remaining to heap start)
    /// 0x00020000 -> [Heap Section     ] (size: variable)
    ///             -> [               ]
    /// 0xFEFF0000 -> [Input Data       ] (size: up to Z_I)
    /// 0xFFFF0000 -> [Stack Section    ] (remaining space)
    /// 0xFFFFFFFF -> [End of memory    ]
    pub fn setPageMap(self: *PVM, program_size: usize, input_data_size: ?usize) !void {
        const span = trace.span(.set_page_map);
        defer span.deinit();

        // Function to round up to nearest page size
        const roundToPage = struct {
            fn roundUp(value: usize) usize {
                return (value + Z_P - 1) & ~@as(usize, Z_P - 1);
            }
        }.roundUp;

        // Calculate section sizes
        const code_size = roundToPage(program_size);
        const input_size = if (input_data_size) |size| roundToPage(size) else 0;

        // Memory layout addresses and sizes
        const layout = .{
            .code = .{
                .address = Z_Z, // Code starts after first empty zone
                .size = code_size,
                .writable = false,
            },
            .heap = .{
                .address = 2 * Z_Z + code_size, // Heap starts after code
                .size = if (code_size > 0) Z_Z else 0, // Allocate heap only if we have code
                .writable = true,
            },
            .input = .{
                .address = 0xFFFFFFFF - Z_Z - Z_I, // Input data below stack
                .size = input_size,
                .writable = false,
            },
            .stack = .{
                .address = 0xFFFFFFFF - Z_Z - Z_I + input_size,
                .size = Z_I - input_size, // Stack gets remaining Z_I space
                .writable = true,
            },
        };

        span.debug("Initializing memory layout:", .{});
        span.debug("  Code:  0x{X:0>8} - size: {}", .{ layout.code.address, layout.code.size });
        span.debug("  Heap:  0x{X:0>8} - size: {}", .{ layout.heap.address, layout.heap.size });
        span.debug("  Input: 0x{X:0>8} - size: {}", .{ layout.input.address, layout.input.size });
        span.debug("  Stack: 0x{X:0>8} - size: {}", .{ layout.stack.address, layout.stack.size });

        // Create new page map with active sections
        var active_sections = std.ArrayList(PageMapConfig).init(self.allocator);
        defer active_sections.deinit();

        // Add sections with non-zero size
        inline for (comptime std.meta.fieldNames(@TypeOf(layout))) |field| {
            const section = @field(layout, field);
            if (section.size > 0) {
                try active_sections.append(.{
                    .address = section.address,
                    .length = section.size,
                    .is_writable = section.writable,
                });
            }
        }

        // Allocate and initialize page map
        self.page_map = try self.allocator.alloc(PageMap, active_sections.items.len);

        for (active_sections.items, 0..) |config, i| {
            span.debug("Initializing page {d}: address=0x{X:0>8}, length={d}, writable={}", .{ i, config.address, config.length, config.is_writable });

            self.page_map[i] = PageMap{
                .address = config.address,
                .length = config.length,
                .is_writable = config.is_writable,
                .data = try self.allocator.allocWithOptions(u8, config.length, 8, null),
            };
        }
    }

    pub fn debugWriteDecompiled(self: *PVM, writer: anytype) !void {
        const span = trace.span(.write_decompiled);
        defer span.deinit();

        const decoder = Decoder.init(self.program.code, self.program.mask);
        var pc: u32 = 0;

        while (pc < self.program.code.len) {
            const i = try decoder.decodeInstruction(pc);
            try writer.print("{d:0>4}: {any}\n", .{ pc, i });
            pc += i.skip_l() + 1;
        }
    }

    // TODO: rename to debugPrintDecompiled
    pub fn decompilePrint(self: *PVM) void {
        const span = trace.span(.decompile_print);
        defer span.deinit();

        self.debugWriteDecompiled(std.io.getStdErr().writer()) catch |err| {
            span.err("Failed to print decompiled code: {}", .{err});
        };
    }

    pub fn debugWriteRegisters(self: *const PVM, writer: anytype) !void {
        const span = trace.span(.write_registers);
        defer span.deinit();

        const reg_names = [_][]const u8{ "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2" };
        try writer.writeAll("\nRegister values:\n");
        for (self.registers, 0..) |reg, i| {
            try writer.print("r{d:<2} ({s:<4}): 0x{X:0>8} ({d})\n", .{
                i, reg_names[i], reg, reg,
            });
        }
    }

    pub fn debugPrintRegisters(self: *const PVM) void {
        const span = trace.span(.print_registers);
        defer span.deinit();

        self.debugWriteRegisters(std.io.getStdErr().writer()) catch |err| {
            span.err("Failed to print registers: {}", .{err});
        };
    }

    fn getGasCost(instruction: InstructionWithArgs) u32 {
        return switch (instruction.instruction) {
            .trap => 0,
            .load_u8 => 1,
            else => 1,
        };
    }

    pub fn innerRunStep(self: *PVM) PVM.Error!void {
        const span = trace.span(.execute_step);
        defer span.deinit();

        const decoded = try self.decoder.decodeInstruction(self.pc);
        span.debug("Executing instruction at PC={X:0>4}: {any}", .{ self.pc, decoded.instruction });
        span.trace("Full instruction with args: {any}", .{decoded});

        if (decoded.instruction == .trap) {
            return Error.Trap;
        }

        const gas_cost = getGasCost(decoded);
        if (self.gas < gas_cost) {
            span.err("Out of gas: required={d}, remaining={d}", .{ gas_cost, self.gas });
            return Error.OutOfGas;
        }

        self.gas -= gas_cost;
        span.debug("Gas remaining after cost: {d}", .{self.gas});

        const execution_span = span.child(.instruction_execution);
        defer execution_span.deinit();

        self.pc = try updatePc(self.pc, self.executeInstruction(decoded) catch |err| {
            execution_span.err("Instruction execution failed: {any}", .{err});
            // Charge one extra gas for error handling
            // NOTE: this is in here to be compatible with
            self.gas -= switch (err) {
                Error.JumpAddressHalt => 0,
                Error.JumpAddressZero => 0,
                else => 1,
            };
            return err;
        });

        execution_span.debug("Updated PC to {X:0>4}", .{self.pc});

        if (execution_span.traceLogLevel()) {
            const register_span = execution_span.child(.registers);
            defer register_span.deinit();
            // Only construct register state string if trace is enabled
            for (self.registers, 0..) |reg, idx| {
                register_span.trace("r{d}=0x{X:0>16}", .{ idx, reg });
            }
        }
    }

    pub fn runStep(self: *PVM) PVM.Error!void {
        const span = trace.span(.run_step);
        defer span.deinit();

        try self.innerRunStep();
    }

    pub fn run(self: *PVM) PVM.Error!void {
        const span = trace.span(.run);
        defer span.deinit();
        span.debug("Starting program execution", .{});

        while (true) {
            try self.runStep();
        }
    }

    const PcOffset = i32;
    fn executeInstruction(self: *PVM, i: InstructionWithArgs) Error!PcOffset {
        switch (i.instruction) {
            // A.5.1 Instructions without Arguments
            .trap => return Error.Trap,
            .fallthrough => {},

            // A.5.2 Instructions with Arguments of One Immediate
            .ecalli => try self.hostCall(@truncate(i.args.OneImm.immediate)),

            // A.5.3 Instructions with Arguments of One Register and One Extended Width Immediate
            .load_imm_64 => {
                const args = i.args.OneRegOneExtImm;
                self.registers[args.register_index] = args.immediate;
            },

            // A.5.4 Instructions with Arguments of Two Immediates
            .store_imm_u8 => {
                const args = i.args.TwoImm;
                try self.storeMemory(u8, @truncate(args.first_immediate), @intCast(args.second_immediate));
            },
            .store_imm_u16 => {
                const args = i.args.TwoImm;
                try self.storeMemory(u16, @truncate(args.first_immediate), @intCast(args.second_immediate));
            },
            .store_imm_u32 => {
                const args = i.args.TwoImm;
                try self.storeMemory(u32, @truncate(args.first_immediate), args.second_immediate);
            },
            .store_imm_u64 => {
                const args = i.args.TwoImm;
                try self.storeMemory(u64, @truncate(args.first_immediate), args.second_immediate);
            },

            // A.5.5 Instructions with Arguments of One Offset
            .jump => {
                return try self.branch(@truncate(i.args.OneOffset.offset));
            },

            // A.5.6 Instructions with Arguments of One Register & One Immediate
            .jump_ind => {
                const args = i.args.OneRegOneImm;
                // graypaper uses ((w_a + v_x) mod u32) we sim this will saturating add
                return self.djump(@truncate(self.registers[args.register_index] +| args.immediate));
            },
            .load_imm => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = args.immediate;
            },
            .load_u8 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemoryUnsignedIntoRegU64(u8, @truncate(args.immediate));
            },
            .load_i8 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemorySignedIntoRegU64(i8, @truncate(args.immediate));
            },
            .load_u16 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemoryUnsignedIntoRegU64(u16, @truncate(args.immediate));
            },
            .load_i16 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemorySignedIntoRegU64(i16, @truncate(args.immediate));
            },
            .load_u32 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemoryUnsignedIntoRegU64(u32, @truncate(args.immediate));
            },
            .load_i32 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemorySignedIntoRegU64(i32, @truncate(args.immediate));
            },
            .load_u64 => {
                const args = i.args.OneRegOneImm;
                self.registers[args.register_index] = try self.loadMemoryUnsignedIntoRegU64(u64, @truncate(args.immediate));
            },
            .store_u8 => {
                const args = i.args.OneRegOneImm;
                try self.storeMemory(u8, @truncate(args.immediate), self.registers[args.register_index]);
            },
            .store_u16 => {
                const args = i.args.OneRegOneImm;
                try self.storeMemory(u16, @truncate(args.immediate), self.registers[args.register_index]);
            },
            .store_u32 => {
                const args = i.args.OneRegOneImm;
                try self.storeMemory(u32, @truncate(args.immediate), self.registers[args.register_index]);
            },
            .store_u64 => {
                const args = i.args.OneRegOneImm;
                try self.storeMemory(u64, @truncate(args.immediate), self.registers[args.register_index]);
            },

            // A.5.7 Instructions with Arguments of One Register & Two Immediates
            .store_imm_ind_u8 => {
                const args = i.args.OneRegTwoImm;
                try self.storeMemory(u8, @truncate(self.registers[args.register_index] +% args.first_immediate), args.second_immediate);
            },
            .store_imm_ind_u16 => {
                const args = i.args.OneRegTwoImm;
                try self.storeMemory(u16, @truncate(self.registers[args.register_index] +% args.first_immediate), args.second_immediate);
            },
            .store_imm_ind_u32 => {
                const args = i.args.OneRegTwoImm;
                try self.storeMemory(u32, @truncate(self.registers[args.register_index] +% args.first_immediate), args.second_immediate);
            },
            .store_imm_ind_u64 => {
                const args = i.args.OneRegTwoImm;
                try self.storeMemory(u64, @truncate(self.registers[args.register_index] +% args.first_immediate), args.second_immediate);
            },

            // A.5.8 Instructions with Arguments of One Register, One Immediate and One Offset
            .load_imm_jump => {
                const args = i.args.OneRegOneImmOneOffset;
                self.registers[args.register_index] = args.immediate;
                return try self.branch(args.offset);
            },

            .branch_eq_imm,
            .branch_ne_imm,
            .branch_lt_u_imm,
            .branch_le_u_imm,
            .branch_ge_u_imm,
            .branch_gt_u_imm,
            .branch_lt_s_imm,
            .branch_le_s_imm,
            .branch_ge_s_imm,
            .branch_gt_s_imm,
            => {
                const args = i.args.OneRegOneImmOneOffset;
                const reg = self.registers[args.register_index];
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
                    return try self.branch(args.offset);
                }
            },

            // A.5.9 Instructions with Arguments of Two Registers
            .move_reg => {
                const args = i.args.TwoReg;
                self.registers[args.first_register_index] = self.registers[args.second_register_index];
            },
            .sbrk => {
                const args = i.args.TwoReg;
                const requested_size = self.registers[args.second_register_index];
                _ = requested_size;

                // search our reserved pages, skip the readonly pages, if we have place in

                // self.registers[args.first_register_index] = xxx; // beginning of the newly allocated heap
            },

            // A.5.10 Instructions with Arguments of Two Registers & One Immediate
            .add_imm_32, .add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] +% args.immediate;
                if (i.instruction == .add_imm_32) {
                    self.registers[args.first_register_index] = @as(u32, @truncate(self.registers[args.first_register_index]));
                }
            },

            .mul_imm_32, .mul_imm_64 => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] *% args.immediate;
                if (i.instruction == .mul_imm_32) {
                    self.registers[args.first_register_index] = @as(u32, @truncate(self.registers[args.first_register_index]));
                }
            },

            // A.5.11 Instructions with Arguments of Two Registers & One Offset
            .branch_eq, .branch_ne, .branch_lt_u, .branch_lt_s, .branch_ge_u, .branch_ge_s => {
                const args = i.args.TwoRegOneOffset;
                const reg1 = self.registers[args.first_register_index];
                const reg2 = self.registers[args.second_register_index];
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
                    return try self.branch(args.offset);
                }
            },

            // A.5.12 Instructions with Arguments of Two Registers and Two Immediates
            .load_imm_jump_ind => {
                const args = i.args.TwoRegTwoImm;
                self.registers[args.first_register_index] = args.first_immediate;
                return self.djump(@truncate(self.registers[args.second_register_index] +% args.second_immediate));
            },

            // A.5.13 Instructions with Arguments of Three Registers
            .add_32, .add_64 => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] +%
                    self.registers[args.second_register_index];
                if (i.instruction == .add_32) {
                    self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                }
            },

            .sub_32, .sub_64 => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] -%
                    self.registers[args.second_register_index];
                if (i.instruction == .sub_32) {
                    self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                }
            },

            .mul_32, .mul_64 => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] *%
                    self.registers[args.second_register_index];
                if (i.instruction == .mul_32) {
                    self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                }
            },

            .div_u_32, .div_u_64 => {
                const args = i.args.ThreeReg;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = if (i.instruction == .div_u_32) 0xFFFFFFFF else 0xFFFFFFFFFFFFFFFF;
                } else {
                    self.registers[args.third_register_index] = @divTrunc(self.registers[args.first_register_index], self.registers[args.second_register_index]);
                    if (i.instruction == .div_u_32) {
                        self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                    }
                }
            },

            .div_s_32, .div_s_64 => {
                const args = i.args.ThreeReg;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = if (i.instruction == .div_s_32) 0xFFFFFFFF else 0xFFFFFFFFFFFFFFFF;
                } else {
                    const is_32 = i.instruction == .div_s_32;
                    const reg1 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(self.registers[args.first_register_index]))))
                    else
                        @as(i64, @bitCast(self.registers[args.first_register_index]));
                    const reg2 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(self.registers[args.second_register_index]))))
                    else
                        @as(i64, @bitCast(self.registers[args.second_register_index]));
                    self.registers[args.third_register_index] = @bitCast(@divTrunc(reg1, reg2));
                }
            },

            .rem_u_32, .rem_u_64 => {
                const args = i.args.ThreeReg;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                } else {
                    self.registers[args.third_register_index] = @rem(self.registers[args.first_register_index], self.registers[args.second_register_index]);
                    if (i.instruction == .rem_u_32) {
                        self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                    }
                }
            },

            .rem_s_32, .rem_s_64 => {
                const args = i.args.ThreeReg;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                } else {
                    const is_32 = i.instruction == .rem_s_32;
                    const reg1 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(self.registers[args.first_register_index]))))
                    else
                        @as(i64, @bitCast(self.registers[args.first_register_index]));
                    const reg2 = if (is_32)
                        @as(i32, @bitCast(@as(u32, @truncate(self.registers[args.second_register_index]))))
                    else
                        @as(i64, @bitCast(self.registers[args.second_register_index]));
                    self.registers[args.third_register_index] = @bitCast(@rem(reg1, reg2));
                }
            },

            .shlo_l_32, .shlo_l_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = if (i.instruction == .shlo_l_32) 0x1F else 0x3F;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] << @intCast(self.registers[args.second_register_index] & mask);
                if (i.instruction == .shlo_l_32) {
                    self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                }
            },

            .shlo_r_32, .shlo_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = if (i.instruction == .shlo_r_32) 0x1F else 0x3F;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] >> @intCast(self.registers[args.second_register_index] & mask);
                if (i.instruction == .shlo_r_32) {
                    self.registers[args.third_register_index] = @as(u32, @truncate(self.registers[args.third_register_index]));
                }
            },

            .shar_r_32, .shar_r_64 => {
                const args = i.args.ThreeReg;
                const mask: u64 = if (i.instruction == .shar_r_32) 0x1F else 0x3F;
                const shift = self.registers[args.second_register_index] & mask;
                if (i.instruction == .shar_r_32) {
                    const value = @as(i32, @bitCast(@as(u32, @truncate(self.registers[args.first_register_index]))));
                    self.registers[args.third_register_index] = @as(u32, @bitCast(value >> @intCast(shift)));
                } else {
                    const value = @as(i64, @bitCast(self.registers[args.first_register_index]));
                    self.registers[args.third_register_index] = @bitCast(value >> @intCast(shift));
                }
            },

            .@"and" => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] &
                    self.registers[args.second_register_index];
            },

            .xor => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] ^
                    self.registers[args.second_register_index];
            },

            .@"or" => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    self.registers[args.first_register_index] |
                    self.registers[args.second_register_index];
            },

            .mul_upper_s_s => {
                const args = i.args.ThreeReg;
                const result = @as(i128, @intCast(@as(i64, @bitCast(self.registers[args.first_register_index])))) *
                    @as(i128, @intCast(@as(i64, @bitCast(self.registers[args.second_register_index]))));
                self.registers[args.third_register_index] = @as(u64, @bitCast(@as(i64, @intCast(result >> 64))));
            },

            .mul_upper_u_u => {
                const args = i.args.ThreeReg;
                const result = @as(u128, self.registers[args.first_register_index]) *
                    @as(u128, self.registers[args.second_register_index]);
                self.registers[args.third_register_index] = @intCast(result >> 64);
            },

            .mul_upper_s_u => {
                const args = i.args.ThreeReg;
                const result = @as(i128, @intCast(@as(i64, @bitCast(self.registers[args.first_register_index])))) *
                    @as(i128, @intCast(self.registers[args.second_register_index]));
                self.registers[args.third_register_index] = @as(u64, @bitCast(@as(i64, @intCast(result >> 64))));
            },

            .set_lt_u => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    if (self.registers[args.first_register_index] < self.registers[args.second_register_index]) 1 else 0;
            },

            .set_lt_s => {
                const args = i.args.ThreeReg;
                self.registers[args.third_register_index] =
                    if (@as(i64, @bitCast(self.registers[args.first_register_index])) <
                    @as(i64, @bitCast(self.registers[args.second_register_index]))) 1 else 0;
            },

            .cmov_iz => {
                const args = i.args.ThreeReg;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                }
            },

            .cmov_nz => {
                const args = i.args.ThreeReg;
                if (self.registers[args.second_register_index] != 0) {
                    self.registers[args.third_register_index] = self.registers[args.first_register_index];
                }
            },

            // A.5.10 Instructions with Arguments of Two Registers & One Immediate (continued)
            .store_ind_u8 => {
                const args = i.args.TwoRegOneImm;
                try self.storeMemory(u8, @truncate(self.registers[args.second_register_index] +% args.immediate), self.registers[args.first_register_index]);
            },
            .store_ind_u16 => {
                const args = i.args.TwoRegOneImm;
                try self.storeMemory(u16, @truncate(self.registers[args.second_register_index] +% args.immediate), self.registers[args.first_register_index]);
            },
            .store_ind_u32 => {
                const args = i.args.TwoRegOneImm;
                try self.storeMemory(u32, @truncate(self.registers[args.second_register_index] +% args.immediate), self.registers[args.first_register_index]);
            },
            .store_ind_u64 => {
                const args = i.args.TwoRegOneImm;
                try self.storeMemory(u64, @truncate(self.registers[args.second_register_index] +% args.immediate), self.registers[args.first_register_index]);
            },

            .load_ind_u8, .load_ind_u16, .load_ind_u32, .load_ind_u64 => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = switch (i.instruction) {
                    .load_ind_u8 => try self.loadMemoryUnsignedIntoRegU64(u8, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    .load_ind_u16 => try self.loadMemoryUnsignedIntoRegU64(u16, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    .load_ind_u32 => try self.loadMemoryUnsignedIntoRegU64(u32, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    .load_ind_u64 => try self.loadMemoryUnsignedIntoRegU64(u64, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    else => unreachable,
                };
            },

            .load_ind_i8, .load_ind_i16, .load_ind_i32 => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = switch (i.instruction) {
                    .load_ind_i8 => try self.loadMemorySignedIntoRegU64(i8, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    .load_ind_i16 => try self.loadMemorySignedIntoRegU64(i16, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    .load_ind_i32 => try self.loadMemorySignedIntoRegU64(i32, @truncate(self.registers[args.second_register_index] +% args.immediate)),
                    else => unreachable,
                };
            },

            .and_imm => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] & args.immediate;
            },

            .xor_imm => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] ^ args.immediate;
            },

            .or_imm => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = self.registers[args.second_register_index] | args.immediate;
            },

            .set_lt_u_imm, .set_lt_s_imm, .set_gt_u_imm, .set_gt_s_imm => {
                const args = i.args.TwoRegOneImm;
                const result = switch (i.instruction) {
                    .set_lt_u_imm => self.registers[args.second_register_index] < args.immediate,
                    .set_lt_s_imm => @as(i64, @bitCast(self.registers[args.second_register_index])) < @as(i64, @bitCast(args.immediate)),
                    .set_gt_u_imm => self.registers[args.second_register_index] > args.immediate,
                    .set_gt_s_imm => @as(i64, @bitCast(self.registers[args.second_register_index])) > @as(i64, @bitCast(args.immediate)),
                    else => unreachable,
                };
                self.registers[args.first_register_index] = if (result) 1 else 0;
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
                    .shlo_l_imm_alt_32, .shlo_l_imm_alt_64 => self.registers[args.second_register_index] & mask,
                    else => unreachable,
                };
                const value = switch (i.instruction) {
                    .shlo_l_imm_32, .shlo_l_imm_64 => self.registers[args.second_register_index],
                    .shlo_l_imm_alt_32, .shlo_l_imm_alt_64 => args.immediate,
                    else => unreachable,
                };
                self.registers[args.first_register_index] = value << @intCast(shift);
                if (i.instruction == .shlo_l_imm_32 or i.instruction == .shlo_l_imm_alt_32) {
                    self.registers[args.first_register_index] = @as(u32, @truncate(self.registers[args.first_register_index]));
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
                    .shlo_r_imm_alt_32, .shlo_r_imm_alt_64 => self.registers[args.second_register_index] & mask,
                    else => unreachable,
                };
                const value = switch (i.instruction) {
                    .shlo_r_imm_32, .shlo_r_imm_64 => self.registers[args.second_register_index],
                    .shlo_r_imm_alt_32, .shlo_r_imm_alt_64 => args.immediate,
                    else => unreachable,
                };
                self.registers[args.first_register_index] = value >> @intCast(shift);
                if (i.instruction == .shlo_r_imm_32 or i.instruction == .shlo_r_imm_alt_32) {
                    self.registers[args.first_register_index] = @as(u32, @truncate(self.registers[args.first_register_index]));
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
                    .shar_r_imm_alt_32, .shar_r_imm_alt_64 => self.registers[args.second_register_index] & mask,
                    else => unreachable,
                };
                const value = switch (i.instruction) {
                    .shar_r_imm_32 => @as(i32, @bitCast(@as(u32, @truncate(self.registers[args.second_register_index])))),
                    .shar_r_imm_64 => @as(i64, @bitCast(self.registers[args.second_register_index])),
                    // FIXME: check this
                    .shar_r_imm_alt_32 => @as(i32, @bitCast(@as(u32, @truncate(args.immediate)))),
                    .shar_r_imm_alt_64 => @as(i64, @bitCast(args.immediate)),
                    else => unreachable,
                };
                self.registers[args.first_register_index] = @bitCast(value >> @intCast(shift));
            },

            .cmov_iz_imm => {
                const args = i.args.TwoRegOneImm;
                if (self.registers[args.second_register_index] == 0) {
                    self.registers[args.first_register_index] = args.immediate;
                }
            },

            .cmov_nz_imm => {
                const args = i.args.TwoRegOneImm;
                if (self.registers[args.second_register_index] != 0) {
                    self.registers[args.first_register_index] = args.immediate;
                }
            },

            .neg_add_imm_32, .neg_add_imm_64 => {
                const args = i.args.TwoRegOneImm;
                self.registers[args.first_register_index] = args.immediate -% self.registers[args.second_register_index];
                if (i.instruction == .neg_add_imm_32) {
                    self.registers[args.first_register_index] = @as(u32, @truncate(self.registers[args.first_register_index]));
                }
            },
        }

        // Default offset
        return @intCast(i.skip_l() + 1);
    }

    fn branch(self: *PVM, o: i32) !PcOffset {
        const span = trace.span(.branch);
        defer span.deinit();

        const b = try updatePc(self.pc, o);

        span.debug("Attempting branch to address 0x{X:0>8}", .{b});

        // Check if the target address is the start of a basic block
        if (!self.isBasicBlockStart(b)) {
            span.err("Invalid branch target - not a basic block start: 0x{X:0>8}", .{b});
            return Error.JumpAddressNotInBasicBlock;
        }

        // Calculate the offset to the target address
        return o;
    }

    pub fn djump(self: *PVM, a: u32) !PcOffset {
        const span = trace.span(.dynamic_jump);
        defer span.deinit();

        span.debug("Dynamic jump to address 0x{X:0>8}", .{a});

        const jump_dest = try self.program.validateJumpAddress(a);

        span.trace("Jump table lookup destination: 0x{X:0>8}", .{jump_dest});

        const offset = if (jump_dest >= self.pc)
            @as(i32, @intCast(jump_dest - self.pc))
        else
            -@as(i32, @intCast(self.pc - jump_dest));

        span.debug("Jump offset calculated: {d}", .{offset});
        return offset;
    }

    fn isBasicBlockStart(self: *PVM, address: u32) bool {
        const span = trace.span(.check_basic_block);
        defer span.deinit();

        // FIXME: binary search
        const is_start = std.mem.indexOfScalar(u32, self.program.basic_blocks, address) != null;
        span.trace("Address 0x{X:0>8} basic block start: {}", .{ address, is_start });
        return is_start;
    }

    /// reads memory and casts the value into an u64 value assuming its unsigned
    fn loadMemoryUnsignedIntoRegU64(self: *PVM, comptime T: type, address: u32) !u64 {
        const span = trace.span(.load_memory_unsigned);
        defer span.deinit();

        span.debug("Loading {d} bytes from address 0x{X:0>8}", .{ @sizeOf(T), address });

        const data = try self.readMemory(address, @sizeOf(T));
        span.trace("Loaded value: 0x{X}", .{data});

        // Read little indian into type, and convert to output type
        return @intCast(std.mem.readInt(T, data[0..@sizeOf(T)], .little));
    }

    /// reads memory and casts the value into an u64 value assuming its signed
    /// ensuring the value is first casted to an i64 before converting into a u64
    fn loadMemorySignedIntoRegU64(self: *PVM, comptime T: type, address: u32) !u64 {
        const span = trace.span(.load_memory_unsigned);
        defer span.deinit();

        span.debug("Loading {d} bytes from address 0x{X:0>8}", .{ @sizeOf(T), address });

        const data = try self.readMemory(address, @sizeOf(T));
        span.trace("Loaded value: 0x{X}", .{data});

        // Read little indian into type, and convert to output type
        return @bitCast(@as(i64, @intCast(std.mem.readInt(T, data[0..@sizeOf(T)], .little))));
    }

    pub fn readMemory(self: *PVM, address: u32, size: usize) ![]u8 {
        const span = trace.span(.read_memory);
        defer span.deinit();

        span.debug("Reading {d} bytes from address 0x{X:0>8}", .{ size, address });

        for (self.page_map) |page| {
            if (address >= page.address and address < page.address + page.length) {
                if (address + size > page.address + page.length) {
                    span.err("Memory access out of bounds: address=0x{X:0>8}, size={d}, page_end=0x{X:0>8}", .{ address, size, page.address + page.length });
                    self.error_data = .{ .page_fault = page.address + page.length };
                    // NOTE: this should be treated as a .page_fault
                    return Error.MemoryAccessOutOfBounds;
                }

                const offset = address - page.address;
                const data = page.data[offset .. offset + size];
                span.trace("Read successful - offset: {d}, data: {any}", .{ offset, data });
                return data;
            }
        }

        span.err("Page fault at address 0x{X:0>8}", .{address});
        self.error_data = .{ .page_fault = address };
        return Error.MemoryPageFault;
    }

    /// No page checking, only bounds are checked
    pub fn initMemory(self: *PVM, address: u32, data: []u8) !void {
        const span = trace.span(.init_memory);
        defer span.deinit();

        span.debug("Initializing {d} bytes at address 0x{X:0>8}", .{ data.len, address });

        for (self.page_map) |page| {
            if (address >= page.address and address < page.address + page.length) {
                if (address + data.len > page.address + page.length) {
                    span.err("Memory access out of bounds: address=0x{X:0>8}, size={d}, page_end=0x{X:0>8}", .{ address, data.len, page.address + page.length });
                    self.error_data = .{ .page_fault = page.address + page.length };
                    return Error.MemoryAccessOutOfBounds;
                }

                const offset = address - page.address;
                @memcpy(page.data[offset..][0..data.len], data);
                // span.trace("Initialization successful - offset: {d}, data: {any}", .{ offset, data });
                return;
            }
        }

        span.err("Page fault at address 0x{X:0>8}", .{address});
        self.error_data = .{ .page_fault = address };
        return Error.MemoryPageFault;
    }

    pub fn writeMemory(self: *PVM, address: u32, data: []u8) !void {
        const span = trace.span(.write_memory);
        defer span.deinit();

        span.debug("Writing {d} bytes to address 0x{X:0>8}", .{ data.len, address });

        for (self.page_map) |page| {
            if (address >= page.address and address < page.address + page.length) {
                if (!page.is_writable) {
                    span.err("Write protected memory at address 0x{X:0>8}", .{address});
                    self.error_data = .{ .page_fault = address };
                    return Error.MemoryWriteProtected;
                }
                if (address + data.len > page.address + page.length) {
                    span.err("Memory access out of bounds: address=0x{X:0>8}, size={d}, page_end=0x{X:0>8}", .{ address, data.len, page.address + page.length });
                    self.error_data = .{ .page_fault = page.address + page.length };
                    return Error.MemoryAccessOutOfBounds;
                }

                const offset = address - page.address;
                std.mem.copyForwards(u8, page.data[offset..], data);
                span.trace("Write successful - offset: {d}, data: {any}", .{ offset, data });
                return;
            }
        }

        span.err("Page fault at address 0x{X:0>8}", .{address});
        self.error_data = .{ .page_fault = address };
        return Error.MemoryPageFault;
    }

    fn storeMemory(self: *PVM, T: type, address: u32, value: u64) !void {
        const span = trace.span(.store_memory);
        defer span.deinit();

        span.debug("Storing value 0x{X:0>8} ({d} bytes) to address 0x{X:0>8}", .{ value, @sizeOf(T), address });

        for (self.page_map) |page| {
            if (address >= page.address and address < page.address + page.length) {
                if (!page.is_writable) {
                    span.err("Write protected memory at address 0x{X:0>8}", .{address});
                    self.error_data = .{ .page_fault = address };
                    return Error.MemoryWriteProtected;
                }
                if (address + @sizeOf(T) > page.address + page.length) {
                    span.err("Memory access out of bounds: address=0x{X:0>8}, size={d}, page_end=0x{X:0>8}", .{ address, @sizeOf(T), page.address + page.length });
                    self.error_data = .{ .page_fault = page.address + page.length };
                    return Error.MemoryAccessOutOfBounds;
                }
                // FIXME: graypaper describes a wrapping operation on the memory and not an MemoryAccessOutOfBounds

                const offset = address - page.address;
                std.mem.writeInt(T, page.data[offset..][0..@sizeOf(T)], @truncate(value), .little);
                return;
            }
        }

        span.err("Page fault at address 0x{X:0>8}", .{address});
        self.error_data = .{ .page_fault = address };
        return Error.MemoryPageFault;
    }

    pub fn clonePageMap(self: *PVM) error{OutOfMemory}![]PageMap {
        const span = trace.span(.clone_page_map);
        defer span.deinit();

        span.debug("Cloning page map with {d} pages", .{self.page_map.len});

        var cloned_page_map = try self.allocator.alloc(PageMap, self.page_map.len);
        errdefer self.allocator.free(cloned_page_map);

        for (self.page_map, 0..) |page, i| {
            span.trace("Cloning page {d}: address=0x{X:0>8}, length={d}", .{ i, page.address, page.length });

            cloned_page_map[i] = PageMap{
                .address = page.address,
                .length = page.length,
                .is_writable = page.is_writable,
                .data = try self.allocator.alignedAlloc(u8, 8, page.data.len),
            };
            @memcpy(cloned_page_map[i].data, page.data);
        }

        return cloned_page_map;
    }

    pub fn freePageMap(self: *PVM, page_map: []PageMap) void {
        const span = trace.span(.free_page_map);
        defer span.deinit();

        span.debug("Freeing page map with {d} pages", .{page_map.len});

        for (page_map) |page| {
            self.allocator.free(page.data);
        }
        self.allocator.free(page_map);
    }
};
