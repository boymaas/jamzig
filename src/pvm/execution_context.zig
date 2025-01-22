const std = @import("std");
const Allocator = std.mem.Allocator;

const Program = @import("program.zig").Program;
const Decoder = @import("decoder.zig").Decoder;
const Memory = @import("memory.zig").Memory;

const HostCallFn = @import("host_calls.zig").HostCallFn;

const trace = @import("tracing.zig").scoped(.pvm);

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

    // simple initialization using only the program
    pub fn initWithRawProgram(allocator: Allocator, raw_program: []const u8) !ExecutionContext {
        // Decode program
        const program = try Program.decode(allocator, raw_program);
        errdefer program.deinit(allocator);

        // Configure memory layout using Memory's standard layout
        const memory = try Memory.init(allocator, Memory.Layout.standard(
            program.code.len,
            0,
        ));
        errdefer memory.deinit();

        // Initialize code section
        try memory.initSectionByName(.code, program.code);

        return ExecutionContext{
            .allocator = allocator,
            .memory = memory,
            .decoder = Decoder.init(program.code, program.mask),
            .host_calls = std.AutoHashMap(u32, HostCallFn).init(allocator),
            .program = program,
        };
    }

    pub fn deinit(self: *ExecutionContext) void {
        self.memory.deinit();
        self.host_calls.deinit();
        self.program.deinit(self.allocator);
    }

    pub fn registerHostCall(self: *ExecutionContext, idx: u32, handler: HostCallFn) !void {
        try self.host_calls.put(idx, handler);
    }
};
