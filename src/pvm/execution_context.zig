const std = @import("std");
const Allocator = std.mem.Allocator;

const Program = @import("program.zig").Program;
const Decoder = @import("decoder.zig").Decoder;
const Memory = @import("memory.zig").Memory;

const trace = @import("../tracing.zig").scoped(.pvm);

pub const ExecutionContext = struct {
    program: Program,
    decoder: Decoder,
    registers: [13]u64,
    memory: Memory,
    // NOTE: we cannot use HostCallMap here due to circular dep
    host_calls: ?*const std.AutoHashMapUnmanaged(u32, *const fn (*ExecutionContext, *anyopaque) HostCallResult),

    gas: i64,
    pc: u32,
    error_data: ?ErrorData,

    pub const HostCallResult = union(enum) {
        play,
        terminal: @import("../pvm.zig").PVM.InvocationException,
    };
    pub const HostCallFn = *const fn (*ExecutionContext, *anyopaque) HostCallResult;
    pub const HostCallMap = std.AutoHashMapUnmanaged(u32, HostCallFn);

    pub const ErrorData = union(enum) {
        page_fault: u32,
        host_call: u32,
    };

    pub fn initStandardProgramCodeFormat(
        allocator: Allocator,
        program_code: []const u8,
        input: []const u8,
        max_gas: u32,
    ) !ExecutionContext {
        const span = trace.span(.init_standard_program);
        defer span.deinit();
        span.debug("Initializing with standard program code format", .{});
        span.trace("Program code size: {d} bytes, input size: {d} bytes", .{ program_code.len, input.len });

        // To keep track wehere we are
        var remaining_bytes = program_code[0..];

        if (remaining_bytes.len < 11) {
            span.err("Incomplete header: expected at least 11 bytes, got {d}", .{remaining_bytes.len});
            return error.IncompleteHeader;
        }

        // first 3 is lenght of read only
        const read_only_size_in_bytes = std.mem.readInt(u24, program_code[0..3], .little);
        // next 3 is lenght of read write
        const read_write_size_in_bytes = std.mem.readInt(u24, program_code[3..6], .little);
        // next 2 is heap in pages
        const heap_size_in_pages = std.mem.readInt(u16, program_code[6..8], .little);
        // next 3 is size of stack
        const stack_size_in_bytes = std.mem.readInt(u24, program_code[8..11], .little);

        span.debug("Header parsed: RO={d} bytes, RW={d} bytes, heap={d} pages, stack={d} bytes", .{
            read_only_size_in_bytes,
            read_write_size_in_bytes,
            heap_size_in_pages,
            stack_size_in_bytes,
        });

        // Register we are just behind the header
        remaining_bytes = remaining_bytes[11..];

        if (remaining_bytes.len < read_only_size_in_bytes + read_write_size_in_bytes) {
            span.err("Memory data segment too small: need {d} bytes, got {d}", .{
                read_only_size_in_bytes + read_write_size_in_bytes,
                remaining_bytes.len,
            });
            return error.MemoryDataSegmentTooSmall;
        }

        // then read the length of read only
        const read_only_data = remaining_bytes[0..read_only_size_in_bytes];
        // then read the length of write only
        const read_write_data = remaining_bytes[read_only_size_in_bytes..][0..read_write_size_in_bytes];

        span.trace("Read-only data: {any}", .{std.fmt.fmtSliceHexLower(read_only_data[0..@min(16, read_only_data.len)])});
        if (read_only_data.len > 16) span.trace("... ({d} more bytes)", .{read_only_data.len - 16});

        span.trace("Read-write data: {any}", .{std.fmt.fmtSliceHexLower(read_write_data[0..@min(16, read_write_data.len)])});
        if (read_write_data.len > 16) span.trace("... ({d} more bytes)", .{read_write_data.len - 16});

        // Update we are at the beginning of our code_data_segment
        remaining_bytes = remaining_bytes[read_only_size_in_bytes + read_write_size_in_bytes ..];

        // read lenght of code
        if (remaining_bytes.len < 4) {
            span.err("Code data segment too small for code length: need 4 bytes, got {d}", .{remaining_bytes.len});
            return error.ProgramCodeFormatCodeDataSegmentTooSmall;
        }
        const code_len_in_bytes = std.mem.readInt(u32, remaining_bytes[0..4], .little);
        span.debug("Code length: {d} bytes", .{code_len_in_bytes});

        remaining_bytes = remaining_bytes[4..];

        if (remaining_bytes.len < code_len_in_bytes) {
            span.err("Code data segment too small for code: need {d} bytes, got {d}", .{
                code_len_in_bytes,
                remaining_bytes.len,
            });
            return error.ProgramCodeFormatCodeDataSegmentTooSmall;
        }

        const code_data = remaining_bytes[0..code_len_in_bytes];
        span.trace("Code data starts with: {any}", .{std.fmt.fmtSliceHexLower(code_data[0..@min(16, code_data.len)])});
        if (code_data.len > 16) span.trace("... ({d} more bytes)", .{code_data.len - 16});

        // then read the actual codeu
        return try initWithMemorySegments(
            allocator,
            code_data,
            read_only_data,
            read_write_data,
            input, // FIXME: need to add input here
            stack_size_in_bytes,
            heap_size_in_pages,
            max_gas,
        );
    }

    pub fn initSimple(
        allocator: Allocator,
        raw_program: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u16,
        max_gas: u32,
    ) !ExecutionContext {
        const span = trace.span(.init_simple);
        defer span.deinit();
        span.debug("Initializing with simple configuration", .{});
        span.trace("Program size: {d} bytes, stack: {d} bytes, heap: {d} pages", .{
            raw_program.len,
            stack_size_in_bytes,
            heap_size_in_pages,
        });

        return try initWithMemorySegments(
            allocator,
            raw_program,
            &[_]u8{},
            &[_]u8{},
            &[_]u8{},
            stack_size_in_bytes,
            heap_size_in_pages,
            max_gas,
        );
    }

    // simple initialization using only the program
    pub fn initWithMemorySegments(
        allocator: Allocator,
        raw_program: []const u8,
        read_only: []const u8,
        read_write: []const u8,
        input: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u16,
        max_gas: u32,
    ) !ExecutionContext {
        const span = trace.span(.init_with_memory_segments);
        defer span.deinit();
        span.debug("Initializing with memory segments", .{});
        span.trace("Program: {d} bytes, RO: {d} bytes, RW: {d} bytes, input: {d} bytes", .{
            raw_program.len,
            read_only.len,
            read_write.len,
            input.len,
        });

        // Configure memory layout with provided segments
        var memory = try Memory.initWithData(
            allocator,
            read_only,
            read_write,
            input,
            stack_size_in_bytes,
            heap_size_in_pages,
        );
        errdefer {
            span.debug("Error occurred, cleaning up memory", .{});
            memory.deinit();
        }

        span.debug("Memory initialized, creating execution context", .{});
        var exec_ctx = try initWithMemory(allocator, raw_program, memory, max_gas);
        exec_ctx.initRegisters(input.len);
        span.debug("Execution context initialized successfully", .{});

        return exec_ctx;
    }

    pub const HALT_PC_VALUE: u32 = 0xFFFF0000;
    pub fn initWithMemory(
        allocator: Allocator,
        raw_program: []const u8,
        memory: Memory,
        max_gas: u32,
    ) !ExecutionContext {
        const span = trace.span(.init_with_memory);
        defer span.deinit();
        span.debug("Initializing with memory and raw program", .{});
        span.trace("Program size: {d} bytes, max gas: {d}", .{ raw_program.len, max_gas });
        span.trace("Program starts with: {any}", .{std.fmt.fmtSliceHexLower(raw_program[0..@min(16, raw_program.len)])});

        // Decode program
        span.debug("Decoding program", .{});
        var program = try Program.decode(allocator, raw_program);
        errdefer {
            span.debug("Error occurred, cleaning up program", .{});
            program.deinit(allocator);
        }

        span.debug("Program decoded successfully, creating execution context", .{});
        // Initialize registers according to specification
        return ExecutionContext{
            .memory = memory,
            .decoder = Decoder.init(program.code, program.mask),
            .host_calls = null,
            .program = program,
            .registers = [_]u64{0} ** 13,
            .pc = 0,
            .error_data = null,
            .gas = max_gas,
        };
    }

    /// Initialize the registers
    pub fn initRegisters(self: *@This(), input_len: usize) void {
        const span = trace.span(.init_registers);
        defer span.deinit();
        span.debug("Initializing registers", .{});

        self.registers[0] = HALT_PC_VALUE; // 0xFFFF0000 Halt PC value
        self.registers[1] = Memory.STACK_BASE_ADDRESS; // Stack pointer
        self.registers[7] = Memory.INPUT_ADDRESS;
        self.registers[8] = input_len;

        span.debug("r0=0x{x:0>16} (HALT_PC), r1=0x{x:0>16} (stack), r7=0x{x:0>16} (input), r8={d} (len)", .{
            self.registers[0],
            self.registers[1],
            self.registers[7],
            self.registers[8],
        });
    }

    /// Clear all registers by setting them to zero
    pub fn clearRegisters(self: *@This()) void {
        const span = trace.span(.clear_registers);
        defer span.deinit();
        span.debug("Clearing all registers", .{});

        @memset(&self.registers, 0);

        span.debug("Registers reset to zero", .{});
    }

    /// Construct the return value by looking determining if we can
    /// read the range between registers 7 and 8. If the range is invalid we return []
    pub fn readSliceBetweenRegister7AndRegister8(self: *@This()) []const u8 {
        const span = trace.span(.return_value_as_slice);
        defer span.deinit();

        span.debug("Reading return value registers r7={d} (0x{x:0>16}) len r8={d} (0x{x:0>16})", .{ self.registers[7], self.registers[7], self.registers[8], self.registers[8] });

        const reg7 = @as(u32, @truncate(self.registers[7]));
        const reg8 = @as(u32, @truncate(self.registers[8]));
        const size = reg8;

        span.debug("Truncated addresses: r7=0x{x:0>8}, r8=0x{x:0>8}, size={d} bytes", .{ reg7, reg8, size });

        return self.memory.readSlice(reg7, size) catch |err| {
            span.err("Failed to read memory slice: {s}", .{@errorName(err)});
            if (self.memory.last_violation) |violation| {
                span.err("Memory violation at address 0x{x:0>8}: {s}", .{ violation.address, @tagName(violation.violation_type) });
            }
            span.debug("Returning empty slice due to memory read error", .{});
            return &[_]u8{};
        };
    }

    pub fn deinit(self: *ExecutionContext, allocator: Allocator) void {
        const span = trace.span(.deinit);
        defer span.deinit();
        span.debug("Deinitializing execution context", .{});

        // Hostcalls are not owned by us
        span.debug("Deinitializing memory", .{});
        self.memory.deinit();

        span.debug("Deinitializing program", .{});
        self.program.deinit(allocator);

        span.debug("Execution context deinitialized", .{});
        self.* = undefined;
    }

    pub fn setHostCalls(self: *ExecutionContext, new_host_calls: *const HostCallMap) void {
        const span = trace.span(.set_host_calls);
        defer span.deinit();
        span.debug("Setting host calls", .{});

        // Replace with the new one
        self.host_calls = new_host_calls;

        span.debug("Host calls set successfully", .{});
    }

    pub fn debugProgram(self: *const ExecutionContext, writer: anytype) !void {
        const span = trace.span(.debug_program);
        defer span.deinit();
        span.debug("Generating program debug output", .{});

        try writer.writeAll("\x1b[1mPROGRAM DECOMPILATION\x1b[0m\n\n");

        // Print register state
        span.debug("Writing register state", .{});
        try writer.writeAll("Registers:\n");
        for (self.registers, 0..) |reg, i| {
            try writer.print("  r{d:<2} = {d:<16} (0x{x:0>16})\n", .{ i, reg, reg });
        }
        try writer.print("\nPC = {d} (0x{x:0>8})\n", .{ self.pc, self.pc });
        try writer.print("Gas remaining: {d}\n\n", .{self.gas});

        // Print jump table
        try writer.writeAll("Jump Table:\n");
        if (self.program.jump_table.indices.len == 0) {
            try writer.writeAll("  <empty>\n");
        } else {
            for (self.program.jump_table.indices, 0..) |target, i| {
                try writer.print("  {d:0>3} => {d:0>4}\n", .{ i, target });
            }
        }
        try writer.writeAll("\nInstructions:\n");
        var iter = self.decoder.iterator();
        while (try iter.next()) |entry| {
            const is_current = entry.pc == self.pc;
            try writer.print("{s}{d:0>4}: ", .{
                if (is_current) "==> " else "    ",
                entry.pc,
            });

            // Print raw bytes (up to 16)
            const raw_bytes = entry.raw;
            const max_bytes = @min(raw_bytes.len, 16);
            for (raw_bytes[0..max_bytes]) |byte| {
                try writer.print("{x:0>2} ", .{byte});
            }

            // Pad remaining space for alignment
            var i: usize = max_bytes;
            while (i < 16) : (i += 1) {
                try writer.writeAll("   ");
            }

            try writer.print(" {}\n", .{entry.inst});
        }
        try writer.writeAll("\n");
    }

    pub fn debugState(self: *const ExecutionContext, context_size_in_instructions: u32, writer: anytype) !void {
        const span = trace.span(.debug_state);
        defer span.deinit();
        span.debug("Generating debug state around PC={d}", .{self.pc});

        const context_size = context_size_in_instructions * 8; // TODO: MaxInstructionSize=16
        const start_pc = if (self.pc >= context_size) self.pc - context_size else 0;

        span.debug("Context window: start_pc={d}, size={d} bytes", .{ start_pc, context_size * 2 });

        // Print here the state of the PC
        std.debug.print("\x1b[1mDEBUG STATE AROUND CURRENT PC @ {}\x1b[0m\n\n", .{self.pc});

        var iter = self.decoder.iterator();
        while (try iter.next()) |entry| {
            if (entry.pc < start_pc) {
                continue;
            }
            if (entry.pc >= start_pc + (2 * context_size)) {
                break;
            }

            const is_current = entry.pc == self.pc;
            try writer.print("{s}{d:0>4}: ", .{
                if (is_current) "==> " else "    ",
                entry.pc,
            });

            // Print raw bytes (up to 16)
            const raw_bytes = entry.raw;
            const max_bytes = @min(raw_bytes.len, 16);
            for (raw_bytes[0..max_bytes]) |byte| {
                try writer.print("{x:0>2} ", .{byte});
            }

            // Pad remaining space for alignment
            var i: usize = max_bytes;
            while (i < 16) : (i += 1) {
                try writer.writeAll("   ");
            }

            try writer.print(" {}\n", .{entry.inst});
        }
    }
};
