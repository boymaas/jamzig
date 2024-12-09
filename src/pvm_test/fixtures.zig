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
        trap,
        halt,
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

pub fn initPVMFromTestVector(allocator: Allocator, test_vector: *const PVMFixture) !PVM {
    var pvm = try PVM.init(allocator, test_vector.program, test_vector.initial_gas);
    errdefer pvm.deinit();

    // Set initial registers
    @memcpy(&pvm.registers, &test_vector.initial_regs);

    // Set initial page map
    try pvm.setPageMap(@as([]PVM.PageMapConfig, @ptrCast(test_vector.initial_page_map)));

    // Set initial memory
    for (test_vector.initial_memory) |chunk| {
        try pvm.writeMemory(chunk.address, chunk.contents);
    }

    // Set initial PC
    pvm.pc = test_vector.initial_pc;

    return pvm;
}

pub fn runTestFixture(allocator: Allocator, test_vector: *const PVMFixture, path: []const u8) !bool {
    var pvm = try initPVMFromTestVector(allocator, test_vector);
    defer pvm.deinit();

    // Create buffers for debug output
    var debug_registers_buffer = std.ArrayList(u8).init(allocator);
    defer debug_registers_buffer.deinit();

    // Write debug info to buffers
    try pvm.debugWriteRegisters(debug_registers_buffer.writer());

    const result = pvm.run();

    // Check if the execution status matches the expected status
    const status_matches: bool = switch (result) {
        // Program executed successfully
        .halt => test_vector.expected_status == PVMFixture.Status.halt,
        // Something happened
        .trap => test_vector.expected_status == PVMFixture.Status.trap,

        // Here we have some mappings that are not present in the

        // NOTE: In the graypaper this is a seperate status which should include the
        // lowest address which caused the page_fault. In the test vectors these are
        // represented as traps.
        .page_fault => test_vector.expected_status == PVMFixture.Status.trap,
        // NOTE: In the graypaper this is a seperate status which should include the
        .panic => test_vector.expected_status == PVMFixture.Status.trap,
        else => false,
    };

    var test_passed = true;
    if (!status_matches) {
        std.debug.print("Status mismatch: expected {}, got {}\n", .{ test_vector.expected_status, result });
        test_passed = false;
    }

    // Check if registers match (General Purpose Registers R0-R12)
    if (!std.mem.eql(u64, &pvm.registers, &test_vector.expected_regs)) {
        std.debug.print("Register mismatch (General Purpose Registers R0-R12):\n", .{});
        std.debug.print("        Input   |    Actual  |   Expected | Diff?\n", .{});
        for (test_vector.initial_regs, pvm.registers, test_vector.expected_regs, 0..) |input, actual, expected, i| {
            const mismatch = if (actual != expected) "*" else " ";
            std.debug.print("R{d:2}: {d:10} | {d:10} | {d:10} | {s}\n", .{ i, input, actual, expected, mismatch });
        }
        test_passed = false;
    }

    // Check if PC matches
    if (pvm.pc != test_vector.expected_pc) {
        std.debug.print("PC mismatch: expected {}, got {}\n", .{ test_vector.expected_pc, pvm.pc });
        test_passed = false;
    }

    // Check if memory matches
    for (test_vector.expected_memory) |expected_chunk| {
        const actual_chunk = try pvm.readMemory(expected_chunk.address, expected_chunk.contents.len);
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
    if (pvm.gas != test_vector.expected_gas) {
        std.debug.print("Gas mismatch: expected {}, got {}\n", .{ test_vector.expected_gas, pvm.gas });
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

        std.debug.print("\nInitial register values:\n{s}", .{debug_registers_buffer.items});
        std.debug.print("\nDecompilation of the program:\n\n", .{});
        pvm.decompilePrint();
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
