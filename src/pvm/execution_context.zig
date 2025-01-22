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

    // simple initialization using only the program
    pub fn initSimple(
        allocator: Allocator,
        raw_program: []const u8,
        stack_size: u24,
        heap_size_in_pages: u16,
        max_gas: u32,
    ) !ExecutionContext {
        // Decode program
        var program = try Program.decode(allocator, raw_program);
        errdefer program.deinit(allocator);

        // Configure memory layout using Memory's standard layout
        var memory = try Memory.init(allocator, try Memory.Layout.standard(
            &[_]u8{},
            &[_]u8{},
            &[_]u8{},
            stack_size,
            heap_size_in_pages,
        ));
        errdefer memory.deinit();

        return ExecutionContext{
            .memory = memory,
            .decoder = Decoder.init(program.code, program.mask),
            .host_calls = std.AutoHashMap(u32, HostCallFn).init(allocator),
            .program = program,
            .registers = [_]u64{0} ** 13,
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
};
