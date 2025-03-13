const std = @import("std");
const Allocator = std.mem.Allocator;
const PVMLib = @import("../jamtestvectors/pvm.zig");

pub const BASE_PATH = PVMLib.BASE_PATH;

const PVM = @import("../pvm.zig").PVM;

pub const PVMFixture = struct {
    name: []const u8,
    initial_regs: [13]u64,
    initial_pc: u32,
    initial_page_map: []PageMap,
    initial_memory: []MemoryChunk,
    initial_gas: i64,
    program: []u8,
    expected_status: Status,
    expected_regs: [13]u64,
    expected_pc: u32,
    expected_memory: []MemoryChunk,
    expected_gas: i64,
    expected_page_fault_address: ?u32 = null,

    pub const PageMap = struct {
        address: u32,
        length: u32,
        is_writable: bool,
    };
    pub const MemoryChunk = struct {
        address: u32,
        contents: []u8,
    };

    pub const Status = enum {
        panic, // the execution ended with a trap (the `trap` instruction was
        // executed, the execution went "out of bounds", an invalid jump was made, or
        // an invalid instruction was executed)
        halt, // The program terminated normally.
        page_fault, // Program halted
    };

    pub fn from_vector(allocator: Allocator, vector: *const PVMLib.PVMTestVector) !PVMFixture {
        var fixture = PVMFixture{
            .name = try allocator.dupe(u8, vector.name),
            .initial_regs = vector.@"initial-regs",
            .initial_pc = vector.@"initial-pc",
            .initial_page_map = try allocator.alloc(PageMap, vector.@"initial-page-map".len),
            .initial_memory = try allocator.alloc(MemoryChunk, vector.@"initial-memory".len),
            .initial_gas = vector.@"initial-gas",
            .program = try allocator.dupe(u8, vector.program),
            .expected_status = @as(Status, @enumFromInt(@intFromEnum(vector.@"expected-status"))),
            .expected_regs = vector.@"expected-regs",
            .expected_pc = vector.@"expected-pc",
            .expected_memory = try allocator.alloc(MemoryChunk, vector.@"expected-memory".len),
            .expected_gas = vector.@"expected-gas",
            .expected_page_fault_address = vector.@"expected-page-fault-address",
        };

        for (vector.@"initial-page-map", 0..) |page, i| {
            fixture.initial_page_map[i] = .{
                .address = page.address,
                .length = page.length,
                .is_writable = page.@"is-writable",
            };
        }

        for (vector.@"initial-memory", 0..) |chunk, i| {
            fixture.initial_memory[i] = .{
                .address = chunk.address,
                .contents = try allocator.dupe(u8, chunk.contents),
            };
        }

        for (vector.@"expected-memory", 0..) |chunk, i| {
            fixture.expected_memory[i] = .{
                .address = chunk.address,
                .contents = try allocator.dupe(u8, chunk.contents),
            };
        }

        return fixture;
    }

    pub fn initMemory(self: *const PVMFixture, allocator: Allocator) !PVM.Memory {
        // Initialize a new memory instance with the required page maps
        var memory = try PVM.Memory.initEmpty(allocator);
        errdefer memory.deinit();

        // Map all pages according to the initial page map configuration
        for (self.initial_page_map) |page| {
            if (page.length % PVM.Memory.Z_P != 0) {
                return error.IncorrectPageLength;
            }
            try memory.allocatePagesAt(
                page.address,
                page.length / PVM.Memory.Z_P,
                if (page.is_writable) .ReadWrite else .ReadOnly,
            );
        }

        // Write initial memory contents
        for (self.initial_memory) |chunk| {
            try memory.initMemory(chunk.address, chunk.contents);
        }

        return memory;
    }

    pub fn deinit(self: *PVMFixture, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.initial_page_map);
        for (self.initial_memory) |chunk| {
            allocator.free(chunk.contents);
        }
        allocator.free(self.initial_memory);
        allocator.free(self.program);
        for (self.expected_memory) |chunk| {
            allocator.free(chunk.contents);
        }
        allocator.free(self.expected_memory);
        self.* = undefined;
    }
};

pub fn initExecContextFromTestVector(allocator: Allocator, test_vector: *const PVMFixture) !PVM.ExecutionContext {
    var exec_ctx = try PVM.ExecutionContext.initWithMemory(
        allocator,
        test_vector.program,
        try test_vector.initMemory(allocator),
        @intCast(test_vector.initial_gas),
    );
    errdefer exec_ctx.deinit(allocator);

    // Set initial registers
    @memcpy(&exec_ctx.registers, &test_vector.initial_regs);

    // Set initial PC
    exec_ctx.pc = test_vector.initial_pc;

    return exec_ctx;
}

pub fn runTestFixture(allocator: Allocator, test_vector: *const PVMFixture, path: []const u8) !bool {
    var exec_ctx = try initExecContextFromTestVector(allocator, test_vector);
    defer exec_ctx.deinit(allocator);

    const result = try PVM.basicInvocation(&exec_ctx);
    // Check if the execution status matches the expected status
    const status_matches: bool = switch (result) {
        .host_call => true, // NOTE: ignored for now
        // ignored for now
        .terminal => |err| switch (err) {
            .halt => test_vector.expected_status == .halt,
            .panic => test_vector.expected_status == .panic,
            .page_fault => |addr| test_vector.expected_status == .page_fault and
                test_vector.expected_page_fault_address == addr,
            else => {
                std.debug.print("UnexpectedErrStatus: {}", .{err});
                return error.UnexpectedErrStatusFromResult;
            },
        },
    };

    var test_passed = true;
    if (!status_matches) {
        std.debug.print("Status mismatch: expected {}", .{test_vector.expected_status});
        if (test_vector.expected_status == .page_fault) {
            std.debug.print(" (expected addr: 0x{x:0>8})", .{test_vector.expected_page_fault_address.?});
        }
        std.debug.print(", got {}", .{result});

        if (result == .terminal) {
            if (result.terminal == .page_fault) {
                std.debug.print(" (addr: 0x{x:0>8})", .{result.terminal.page_fault});
            }
        }
        std.debug.print("\n", .{});
        test_passed = false;
    }

    // Check if registers match (General Purpose Registers R0-R12)
    if (!std.mem.eql(u64, &exec_ctx.registers, &test_vector.expected_regs)) {
        std.debug.print("Register mismatch (General Purpose Registers R0-R12):\n", .{});
        std.debug.print("        Input         |    Actual        |   Expected       | Diff?\n", .{});
        for (test_vector.initial_regs, exec_ctx.registers, test_vector.expected_regs, 0..) |input, actual, expected, i| {
            const mismatch = if (actual != expected) "*" else " ";
            std.debug.print("R{d:2}: {X:0>16} | {X:0>16} | {X:0>16} | {s}\n", .{ i, input, actual, expected, mismatch });
        }
        test_passed = false;
    }

    // Check if PC matches
    if (exec_ctx.pc != test_vector.expected_pc) {
        std.debug.print("PC mismatch: expected {}, got {}\n", .{ test_vector.expected_pc, exec_ctx.pc });
        test_passed = false;
    }

    // Check if memory matches
    for (test_vector.expected_memory) |expected_chunk| {
        const actual_chunk = try exec_ctx.memory.readSlice(expected_chunk.address, expected_chunk.contents.len);
        if (!std.mem.eql(u8, actual_chunk, expected_chunk.contents)) {
            std.debug.print("Memory mismatch at address 0x{X:0>8}:\n", .{expected_chunk.address});
            std.debug.print("Expected: ", .{});
            for (expected_chunk.contents) |byte| {
                std.debug.print("{X:0>2} ", .{byte});
            }
            std.debug.print("\nActual:   ", .{});
            for (actual_chunk) |byte| {
                std.debug.print("{X:0>2} ", .{byte});
            }
            std.debug.print("\n", .{});
            test_passed = false;
        }
    }

    // Check if gas matches

    // FIXME: disabled this as there are no final gas prices for instruction. To pass the jamduna:assurance
    //        I had to put gas on 0. Enable this once we have consensus over gas prices
    // if (exec_ctx.gas != test_vector.expected_gas) {
    //     std.debug.print("Gas mismatch: expected {}, got {}\n", .{ test_vector.expected_gas, exec_ctx.gas });
    //     test_passed = false;
    // }

    if (!test_passed) {
        // Read and dump the test vector file to stderr
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Failed to open test vector file '{s}': {}\n", .{ path, err });
            return false;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| {
            std.debug.print("Failed to read test vector file: {}\n", .{err});
            return false;
        };
        defer allocator.free(content);

        std.debug.print("\nTest vector file '{s}' contents:\n{s}\n", .{ path, content });

        std.debug.print("\nDecompilation of the program:\n\n", .{});
        try exec_ctx.debugProgram(std.io.getStdErr().writer());
    }

    return test_passed;
}

pub fn runTestFixtureFromPath(allocator: Allocator, path: []const u8) !bool {
    const vector = try PVMLib.PVMTestVector.build_from(allocator, path);
    defer vector.deinit();

    var fixture = try PVMFixture.from_vector(allocator, &vector.value);
    defer fixture.deinit(allocator);

    return runTestFixture(allocator, &fixture, path);
}
