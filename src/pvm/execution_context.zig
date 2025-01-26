const std = @import("std");
const Allocator = std.mem.Allocator;

const Program = @import("program.zig").Program;
const Decoder = @import("decoder.zig").Decoder;
const Memory = @import("memory.zig").Memory;

const HostCallFn = @import("host_calls.zig").HostCallFn;

const trace = @import("../tracing.zig").scoped(.pvm);

pub const ExecutionContext = struct {
    program: Program,
    decoder: Decoder,
    registers: [13]u64,
    memory: Memory,
    host_calls: std.AutoHashMap(u32, HostCallFn),

    gas: i64,
    pc: u32,
    error_data: ?ErrorData,

    pub const ErrorData = union(enum) {
        page_fault: u32,
        host_call: u32,
    };

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
        // Decode program
        var program = try Program.decode(allocator, raw_program);
        errdefer program.deinit(allocator);

        // Configure memory layout with provided segments
        var memory = try Memory.init(
            allocator,
            read_only,
            read_write,
            input,
            stack_size_in_bytes,
            heap_size_in_pages,
        );
        errdefer memory.deinit();

        return try initWithMemory(allocator, raw_program, memory, max_gas);
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
        var registers = [_]u64{0} ** 13;
        registers[0] = HALT_PC_VALUE; // 0xFFFF0000 Halt PC value
        registers[1] = Memory.STACK_BASE_ADDRESS; // Stack pointer
        registers[7] = Memory.INPUT_ADDRESS;
        registers[8] = memory.input.len;

        return ExecutionContext{
            .memory = memory,
            .decoder = Decoder.init(program.code, program.mask),
            .host_calls = std.AutoHashMap(u32, HostCallFn).init(allocator),
            .program = program,
            .registers = registers,
            .pc = 0,
            .error_data = null,
            .gas = max_gas,
        };
    }

    pub fn deinit(self: *ExecutionContext, allocator: Allocator) void {
        self.memory.deinit();
        self.host_calls.deinit();
        self.program.deinit(allocator);
    }

    pub fn registerHostCall(self: *ExecutionContext, idx: u32, handler: HostCallFn) !void {
        try self.host_calls.put(idx, handler);
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
