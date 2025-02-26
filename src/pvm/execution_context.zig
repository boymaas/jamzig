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
    host_calls: std.AutoHashMapUnmanaged(u32, *const fn (*ExecutionContext) HostCallResult),

    gas: i64,
    pc: u32,
    error_data: ?ErrorData,

    pub const HostCallResult = union(enum) {
        play,
        page_fault: u32,
    };
    pub const HostCallFn = *const fn (*ExecutionContext) HostCallResult;
    pub const HostCallMap = std.AutoHashMapUnmanaged(u32, *const fn (*ExecutionContext) HostCallResult);

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
        // To keep track wehere we are
        var remaining_bytes = program_code[0..];

        if (remaining_bytes.len < 11) {
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

        // Register we are just behind the header
        remaining_bytes = remaining_bytes[11..];

        if (remaining_bytes.len < read_only_size_in_bytes + read_write_size_in_bytes) {
            return error.MemoryDataSegmentTooSmall;
        }

        // then read the length of read only
        const read_only_data = remaining_bytes[0..read_only_size_in_bytes];
        // then read the length of write only
        const read_write_data = remaining_bytes[read_only_size_in_bytes..][0..read_write_size_in_bytes];

        // Update we are at the beginning of our code_data_segment
        remaining_bytes = remaining_bytes[read_only_size_in_bytes + read_write_size_in_bytes ..];

        // read lenght of code
        if (remaining_bytes.len < 4) {
            return error.ProgramCodeFormatCodeDataSegmentTooSmall;
        }
        const code_len_in_bytes = std.mem.readInt(u32, remaining_bytes[0..4], .little);

        remaining_bytes = remaining_bytes[4..];

        if (remaining_bytes.len < code_len_in_bytes) {
            return error.ProgramCodeFormatCodeDataSegmentTooSmall;
        }

        const code_data = remaining_bytes[0..code_len_in_bytes];

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
        // Configure memory layout with provided segments
        var memory = try Memory.initWithData(
            allocator,
            read_only,
            read_write,
            input,
            stack_size_in_bytes,
            heap_size_in_pages,
        );
        errdefer memory.deinit();

        var exec_ctx = try initWithMemory(allocator, raw_program, memory, max_gas);
        exec_ctx.initRegisters(input.len);

        return exec_ctx;
    }

    pub const HALT_PC_VALUE: u32 = 0xFFFF0000;
    pub fn initWithMemory(
        allocator: Allocator,
        raw_program: []const u8,
        memory: Memory,
        max_gas: u32,
    ) !ExecutionContext {
        // Decode program
        var program = try Program.decode(allocator, raw_program);
        errdefer program.deinit(allocator);

        // Initialize registers according to specification
        return ExecutionContext{
            .memory = memory,
            .decoder = Decoder.init(program.code, program.mask),
            .host_calls = .{},
            .program = program,
            .registers = [_]u64{0} ** 13,
            .pc = 0,
            .error_data = null,
            .gas = max_gas,
        };
    }

    /// Initialize the registers
    pub fn initRegisters(self: *@This(), input_len: usize) void {
        self.registers[0] = HALT_PC_VALUE; // 0xFFFF0000 Halt PC value
        self.registers[1] = Memory.STACK_BASE_ADDRESS; // Stack pointer
        self.registers[7] = Memory.INPUT_ADDRESS;
        self.registers[8] = input_len;
    }

    /// Clear all registers by setting them to zero
    pub fn clearRegisters(self: *@This()) void {
        @memset(&self.registers, 0);
    }

    /// Construct the return value by looking determining if we can
    /// read the range between registers 7 and 8. If the range is invalid we return []
    pub fn readSliceBetweenRegister7AndRegister8(self: *@This()) []const u8 {
        const span = trace.span(.return_value_as_slice);
        defer span.deinit();

        if (self.registers[7] < self.registers[8]) {
            const reg7 = @as(u32, @truncate(self.registers[7]));
            const reg8 = @as(u32, @truncate(self.registers[8]));
            return self.memory.readSlice(reg7, reg8 - reg7) catch {
                return &[_]u8{};
            };
        }

        return &[_]u8{};
    }

    pub fn deinit(self: *ExecutionContext, allocator: Allocator) void {
        self.memory.deinit();
        self.host_calls.deinit(allocator);
        self.program.deinit(allocator);
    }

    pub fn registerHostCall(self: *ExecutionContext, allocator: std.mem.Allocator, idx: u32, handler: HostCallFn) !void {
        try self.host_calls.put(allocator, idx, handler);
    }

    pub fn setHostCalls(self: *ExecutionContext, allocator: std.mem.Allocator, new_host_calls: HostCallMap) void {
        // Deinit the old host calls map
        self.host_calls.deinit(allocator);
        // Replace with the new one
        self.host_calls = new_host_calls;
    }

    pub fn debugProgram(self: *const ExecutionContext, writer: anytype) !void {
        try writer.writeAll("\x1b[1mPROGRAM DECOMPILATION\x1b[0m\n\n");

        // Print register state
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
        const context_size = context_size_in_instructions * 8; // TODO: MaxInstructionSize=16
        const start_pc = if (self.pc >= context_size) self.pc - context_size else 0;

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
