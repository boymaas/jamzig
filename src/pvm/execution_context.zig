const std = @import("std");
const Allocator = std.mem.Allocator;

const codec = @import("../codec.zig");
const types = @import("../types.zig");
const HostCallError = @import("../pvm_invocations/host_calls.zig").HostCallError;

const Program = @import("program.zig").Program;
const Decoder = @import("decoder.zig").Decoder;
const Memory = @import("memory.zig").Memory;
const ExecutionTrace = @import("execution_trace.zig").ExecutionTrace;

const trace = @import("tracing").scoped(.pvm);

pub const ExecutionContext = struct {
    program: Program,
    decoder: Decoder,
    registers: [13]u64,
    memory: Memory,
    // Cannot use HostCallsConfig directly due to circular dependency
    host_calls: ?*const anyopaque, // Will be cast to *const PVM.HostCallsConfig when used

    gas: i64,
    pc: u32,
    error_data: ?ErrorData,
    exec_trace: ExecutionTrace,

    pub const HostCallResult = union(enum) {
        play,
        terminal: @import("../pvm.zig").PVM.InvocationException,
    };
    pub const HostCallFn = *const fn (*ExecutionContext, *anyopaque) HostCallError!HostCallResult;
    pub const HostCallMap = std.AutoHashMapUnmanaged(u32, HostCallFn);

    pub const ErrorData = union(enum) {
        page_fault: u32,
        host_call: u32,
    };

    pub fn initStandardProgramCodeFormatWithMetadata(
        allocator: Allocator,
        program_blob: []const u8,
        input: []const u8,
        max_gas: u32,
        dynamic_allocation: bool,
    ) !ExecutionContext {
        const result = try codec.decoder.decodeInteger(program_blob);
        if (result.value + result.bytes_read > program_blob.len) {
            return error.MetadataSizeTooLarge;
        }

        _ = program_blob[result.bytes_read..][0..result.value];
        const standard_program_format = program_blob[result.bytes_read + result.value ..];

        return initStandardProgramCodeFormat(
            allocator,
            standard_program_format,
            input,
            max_gas,
            dynamic_allocation,
        );
    }

    /// Initialize execution context with standard program code format.
    /// This implements the Y function initialization from the JAM specification.
    ///
    /// @param program_code The program blob containing: E_3(|o|) ∥ E_3(|w|) ∥ E_2(z) ∥ E_3(s) ∥ o ∥ w ∥ E_4(|c|) ∥ c
    /// @param input The argument data (a) passed separately from the program blob, limited to Z_I bytes
    pub fn initStandardProgramCodeFormat(
        allocator: Allocator,
        program_code: []const u8,
        input: []const u8,
        max_gas: u32,
        dynamic_allocation: bool,
    ) !ExecutionContext {
        const span = trace.span(@src(), .init_standard_program);
        defer span.deinit();
        span.debug("Initializing with standard program code format", .{});
        span.trace("Program code size: {d} bytes, input size: {d} bytes", .{ program_code.len, input.len });

        var remaining_bytes = program_code[0..];

        if (remaining_bytes.len < 11) {
            span.err("Incomplete header: expected at least 11 bytes, got {d}", .{remaining_bytes.len});
            return error.IncompleteHeader;
        }

        const read_only_size_in_bytes = std.mem.readInt(u24, program_code[0..3], .little);
        const read_write_size_in_bytes = std.mem.readInt(u24, program_code[3..6], .little);
        const heap_size_in_pages = std.mem.readInt(u16, program_code[6..8], .little);
        const stack_size_in_bytes = std.mem.readInt(u24, program_code[8..11], .little);

        span.debug("Header parsed: RO={d} bytes, RW={d} bytes, heap={d} pages, stack={d} bytes", .{
            read_only_size_in_bytes,
            read_write_size_in_bytes,
            @as(u32, heap_size_in_pages),
            stack_size_in_bytes,
        });

        remaining_bytes = remaining_bytes[11..];

        if (remaining_bytes.len < read_only_size_in_bytes + read_write_size_in_bytes) {
            span.err("Memory data segment too small: need {d} bytes, got {d}", .{
                read_only_size_in_bytes + read_write_size_in_bytes,
                remaining_bytes.len,
            });
            return error.MemoryDataSegmentTooSmall;
        }

        const read_only_data = remaining_bytes[0..read_only_size_in_bytes];
        const read_write_data = remaining_bytes[read_only_size_in_bytes..][0..read_write_size_in_bytes];

        span.trace("Read-only data: {any}", .{std.fmt.fmtSliceHexLower(read_only_data[0..@min(16, read_only_data.len)])});
        if (read_only_data.len > 16) span.trace("... ({d} more bytes)", .{read_only_data.len - 16});

        span.trace("Read-write data: {any}", .{std.fmt.fmtSliceHexLower(read_write_data[0..@min(16, read_write_data.len)])});
        if (read_write_data.len > 16) span.trace("... ({d} more bytes)", .{read_write_data.len - 16});

        remaining_bytes = remaining_bytes[read_only_size_in_bytes + read_write_size_in_bytes ..];

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

        return try initWithMemorySegments(
            allocator,
            code_data,
            read_only_data,
            read_write_data,
            input,
            stack_size_in_bytes,
            @as(u32, heap_size_in_pages),
            max_gas,
            dynamic_allocation,
        );
    }

    pub fn initSimple(
        allocator: Allocator,
        raw_program: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u32,
        max_gas: u32,
        dynamic_allocation: bool,
    ) !ExecutionContext {
        const span = trace.span(@src(), .init_simple);
        defer span.deinit();
        span.debug("Initializing with simple configuration", .{});
        span.trace("Program size: {d} bytes, stack: {d} bytes, heap: {d} pages", .{
            raw_program.len,
            stack_size_in_bytes,
            @as(u32, heap_size_in_pages),
        });

        return try initWithMemorySegments(
            allocator,
            raw_program,
            &[_]u8{},
            &[_]u8{},
            &[_]u8{},
            stack_size_in_bytes,
            @as(u32, heap_size_in_pages),
            max_gas,
            dynamic_allocation,
        );
    }

    pub fn initWithMemorySegments(
        allocator: Allocator,
        raw_program: []const u8,
        read_only: []const u8,
        read_write: []const u8,
        input: []const u8,
        stack_size_in_bytes: u24,
        heap_size_in_pages: u32,
        max_gas: u32,
        dynamic_allocation: bool,
    ) !ExecutionContext {
        const span = trace.span(@src(), .init_with_memory_segments);
        defer span.deinit();
        span.debug("Initializing with memory segments", .{});
        span.trace("Program: {d} bytes, RO: {d} bytes, RW: {d} bytes, input: {d} bytes", .{
            raw_program.len,
            read_only.len,
            read_write.len,
            input.len,
        });
        span.debug("Dynamic allocation: {}", .{dynamic_allocation});

        // Configure memory layout with provided segments
        var memory = try Memory.initWithData(
            allocator,
            read_only,
            read_write,
            input,
            stack_size_in_bytes,
            @as(u32, heap_size_in_pages),
            dynamic_allocation,
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
        const span = trace.span(@src(), .init_with_memory);
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
        const trace_mode = blk: {
            // Check for pvm_exec=compact
            if (@import("tracing").findScope("pvm_exec_compact") != null) {
                break :blk ExecutionTrace.TraceMode.compact;
            }
            // Check for pvm_exec (verbose)
            if (@import("tracing").findScope("pvm_exec") != null) {
                break :blk ExecutionTrace.TraceMode.verbose;
            }
            break :blk ExecutionTrace.TraceMode.disabled;
        };

        return ExecutionContext{
            .memory = memory,
            .decoder = Decoder.init(program.code, program.mask),
            .host_calls = null,
            .program = program,
            .registers = [_]u64{0} ** 13,
            .pc = 0,
            .error_data = null,
            .gas = max_gas,
            .exec_trace = ExecutionTrace.initWithMode(max_gas, trace_mode),
        };
    }

    pub fn initRegisters(self: *@This(), input_len: usize) void {
        const span = trace.span(@src(), .init_registers);
        defer span.deinit();
        span.debug("Initializing registers", .{});

        self.registers[0] = HALT_PC_VALUE;
        self.registers[1] = Memory.STACK_BASE_ADDRESS;
        self.registers[7] = Memory.INPUT_ADDRESS;
        self.registers[8] = input_len;

        span.debug("r0=0x{x:0>16} (HALT_PC), r1=0x{x:0>16} (stack), r7=0x{x:0>16} (input), r8={d} (len)", .{
            self.registers[0],
            self.registers[1],
            self.registers[7],
            self.registers[8],
        });

        self.exec_trace.initRegisterTracking(&self.registers);
    }

    pub fn clearRegisters(self: *@This()) void {
        const span = trace.span(@src(), .clear_registers);
        defer span.deinit();
        span.debug("Clearing all registers", .{});

        @memset(&self.registers, 0);

        span.debug("Registers reset to zero", .{});
    }

    pub fn readSliceBetweenRegister7AndRegister8(self: *@This()) Memory.MemorySlice {
        const span = trace.span(@src(), .return_value_as_slice);
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
            return .{ .buffer = &[_]u8{} };
        };
    }

    pub fn deinit(self: *ExecutionContext, allocator: Allocator) void {
        const span = trace.span(@src(), .deinit);
        defer span.deinit();
        span.debug("Deinitializing execution context", .{});

        span.debug("Deinitializing memory", .{});
        self.memory.deinit();

        span.debug("Deinitializing program", .{});
        self.program.deinit(allocator);

        span.debug("Execution context deinitialized", .{});
        self.* = undefined;
    }

    pub fn setHostCalls(self: *ExecutionContext, new_host_calls: *const anyopaque) void {
        const span = trace.span(@src(), .set_host_calls);
        defer span.deinit();
        span.debug("Setting host calls", .{});

        self.host_calls = new_host_calls;

        span.debug("Host calls set successfully", .{});
    }

    /// Read memory with protocol error handling
    pub fn readMemory(self: *ExecutionContext, addr: u32, size: usize) HostCallError!Memory.MemorySlice {
        return self.memory.readSlice(addr, size) catch |err| switch (err) {
            error.PageFault => return HostCallError.MemoryAccessFault,
            else => {
                std.log.err("Unexpected memory read error: {}", .{err});
                return HostCallError.MemoryAccessFault;
            },
        };
    }

    /// Write memory with protocol error handling
    pub fn writeMemory(self: *ExecutionContext, addr: u32, data: []const u8) HostCallError!void {
        self.memory.writeSlice(addr, data) catch |err| switch (err) {
            error.PageFault => return HostCallError.MemoryAccessFault,
            else => {
                std.log.err("Unexpected memory write error: {}", .{err});
                return HostCallError.MemoryAccessFault;
            },
        };
    }

    /// Read a hash from memory with protocol error handling
    pub fn readHash(self: *ExecutionContext, addr: u32) HostCallError!types.Hash {
        return self.memory.readHash(addr) catch return HostCallError.MemoryAccessFault;
    }

    /// Enable or disable dynamic memory allocation
    pub fn setDynamicMemoryAllocation(self: *ExecutionContext, enable: bool) void {
        const span = trace.span(@src(), .set_dynamic_memory);
        defer span.deinit();
        span.debug("Setting dynamic memory allocation: {}", .{enable});

        self.memory.dynamic_allocation_enabled = enable;

        span.debug("Dynamic memory allocation set successfully", .{});
    }

    pub fn overrideStackSize(self: *ExecutionContext, new_stack_size_bytes: u32) !void {
        const span = trace.span(@src(), .override_stack_size);
        defer span.deinit();
        span.debug("Overriding stack size to {d} bytes", .{new_stack_size_bytes});

        const MIN_STACK_SIZE = 4096;
        if (new_stack_size_bytes < MIN_STACK_SIZE) {
            span.err("Stack size {d} is below minimum {d}", .{ new_stack_size_bytes, MIN_STACK_SIZE });
            return error.InvalidStackSize;
        }

        if (new_stack_size_bytes % 4096 != 0) {
            span.err("Stack size {d} is not page-aligned", .{new_stack_size_bytes});
            return error.InvalidStackSize;
        }

        const new_stack_size_pages = new_stack_size_bytes / 4096;
        const current_stack_size_pages = self.memory.stack_size_in_pages;

        span.debug("Current stack: {d} pages, new stack: {d} pages", .{ current_stack_size_pages, new_stack_size_pages });

        if (new_stack_size_pages == current_stack_size_pages) {
            span.debug("Stack size unchanged, no reallocation needed", .{});
            return;
        }

        const current_stack_bottom = try Memory.STACK_BOTTOM_ADDRESS(@intCast(current_stack_size_pages));

        self.memory.page_table.freePages(current_stack_bottom, current_stack_size_pages) catch |err| {
            span.err("Failed to free existing stack pages: {s}", .{@errorName(err)});
            return err;
        };

        span.debug("Removing {d} existing stack pages starting at 0x{X:0>8}", .{ current_stack_size_pages, current_stack_bottom });

        const new_stack_bottom = try Memory.STACK_BOTTOM_ADDRESS(@intCast(new_stack_size_pages));
        span.debug("Allocating {d} new stack pages starting at 0x{X:0>8}", .{ new_stack_size_pages, new_stack_bottom });

        try self.memory.page_table.allocatePages(
            new_stack_bottom,
            new_stack_size_pages,
            Memory.Page.Flags.ReadWrite,
        );

        self.memory.stack_size_in_pages = @intCast(new_stack_size_pages);

        span.debug("Stack size override completed successfully", .{});
    }

    pub fn debugProgram(self: *const ExecutionContext, writer: anytype) !void {
        const span = trace.span(@src(), .debug_program);
        defer span.deinit();
        span.debug("Generating program debug output", .{});

        try writer.writeAll("\x1b[1mPROGRAM DECOMPILATION\x1b[0m\n\n");

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

            const raw_bytes = entry.raw;
            const max_bytes = @min(raw_bytes.len, 16);
            for (raw_bytes[0..max_bytes]) |byte| {
                try writer.print("{x:0>2} ", .{byte});
            }

            var i: usize = max_bytes;
            while (i < 16) : (i += 1) {
                try writer.writeAll("   ");
            }

            try writer.print(" {}\n", .{entry.inst});
        }
        try writer.writeAll("\n");
    }

    pub fn debugState(self: *const ExecutionContext, context_size_in_instructions: u32, writer: anytype) !void {
        const span = trace.span(@src(), .debug_state);
        defer span.deinit();
        span.debug("Generating debug state around PC={d}", .{self.pc});

        const context_size = context_size_in_instructions * 8; // TODO: MaxInstructionSize=16
        const start_pc = if (self.pc >= context_size) self.pc - context_size else 0;

        span.debug("Context window: start_pc={d}, size={d} bytes", .{ start_pc, context_size * 2 });

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

            const raw_bytes = entry.raw;
            const max_bytes = @min(raw_bytes.len, 16);
            for (raw_bytes[0..max_bytes]) |byte| {
                try writer.print("{x:0>2} ", .{byte});
            }

            var i: usize = max_bytes;
            while (i < 16) : (i += 1) {
                try writer.writeAll("   ");
            }

            try writer.print(" {}\n", .{entry.inst});
        }
    }
};
