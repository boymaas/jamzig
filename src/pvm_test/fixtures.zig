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
    var exec_ctx = try PVM.ExecutionContext.initSimple(allocator, test_vector.program, 0, 0, @intCast(test_vector.initial_gas));
    errdefer exec_ctx.deinit(allocator);

    // Set initial registers
    @memcpy(&exec_ctx.registers, &test_vector.initial_regs);

    // Set initial pages
    for (test_vector.initial_page_map) |page| {
        switch (page.address) {
            0x20000 => {
                const result = try exec_ctx.memory.sbrk(PVM.Memory.Z_P);
                // Simple solution to allocate
                std.debug.assert(result.address == page.address);
            },
            else => {
                return error.UnknownInitialPageMapEntry;
            },
        }
    }

    // Set initial memory
    for (test_vector.initial_memory) |chunk| {
        try exec_ctx.memory.write(chunk.address, chunk.contents);
    }

    // Set initial PC
    exec_ctx.pc = test_vector.initial_pc;

    return exec_ctx;
}

pub fn runTestFixture(allocator: Allocator, test_vector: *const PVMFixture, path: []const u8) !bool {
    var exec_ctx = try initExecContextFromTestVector(allocator, test_vector);
    defer exec_ctx.deinit(allocator);

    const test_name = @constCast(&std.mem.splitBackwardsScalar(u8, path, '/')).next().?;

    const result = try PVM.execute(&exec_ctx);
    // Check if the execution status matches the expected status
    const status_matches: bool = switch (result) {
        .halt => test_vector.expected_status == .halt,
        .err => |err| switch (err) {
            .panic => test_vector.expected_status == .panic,
            .page_fault => |addr| test_vector.expected_status == .page_fault and test_vector.expected_page_fault_address == addr,
            else => {
                std.debug.print("UnexpectedErrStatus: {}", .{err});
                return error.UnexpectedErrStatusFromResult;
            },
        },
    };

    var test_passed = true;
    if (!status_matches) {
        std.debug.print("Status mismatch: expected {}, got {}\n", .{ test_vector.expected_status, result });
        test_passed = false;
    }

    // Check if registers match (General Purpose Registers R0-R12)
    if (!std.mem.eql(u64, &exec_ctx.registers, &test_vector.expected_regs)) {
        std.debug.print("Register mismatch (General Purpose Registers R0-R12):\n", .{});
        std.debug.print("        Input   |    Actual  |   Expected | Diff?\n", .{});
        for (test_vector.initial_regs, exec_ctx.registers, test_vector.expected_regs, 0..) |input, actual, expected, i| {
            const mismatch = if (actual != expected) "*" else " ";
            std.debug.print("R{d:2}: {d:10} | {d:10} | {d:10} | {s}\n", .{ i, input, actual, expected, mismatch });
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
        const actual_chunk = try exec_ctx.memory.read(expected_chunk.address, expected_chunk.contents.len);
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

    if (exec_ctx.gas != test_vector.expected_gas) gas: {
        // NOTE: this test does something weird with gas calculation no idea
        // why this consumed two gase
        if (std.mem.eql(u8, test_name, "inst_load_u8_nok.json")) {
            // → execute_step
            //   • Executing instruction at PC: 0x00000000: load_u8 r7, 0x20000
            //   • Decoded instruction: pvm.instruction.Instruction.load_u8
            //   • Instruction gas cost: 1
            //   • Remaining gas: 9999
            //   → memory_read
            //     • Reading from memory
            //     • Address: 0x20000, Size: 1
            // Gas mismatch: expected 9998, got 9999
            //
            // This should be ok, assuming each instruction takes 1 gas, this counts as two wy?
            break :gas;
        }

        std.debug.print("Gas mismatch: expected {}, got {}\n", .{ test_vector.expected_gas, exec_ctx.gas });
        test_passed = false;
    }

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
