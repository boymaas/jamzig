const std = @import("std");
const Allocator = std.mem.Allocator;
const PMVLib = @import("../tests/vectors/libs/pvm.zig");

const PVM = @import("../pvm.zig").PVM;

pub const PVMFixture = struct {
    name: []const u8,
    initial_regs: [13]u32,
    initial_pc: u32,
    initial_page_map: []PageMap,
    initial_memory: []MemoryChunk,
    initial_gas: i64,
    program: []u8,
    expected_status: Status,
    expected_regs: [13]u32,
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

    pub fn from_vector(allocator: Allocator, vector: *const PMVLib.PVMTestVector) !PVMFixture {
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
                .is_writable = page.is_writable,
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
    }
};

pub fn initPVMFromTestVector(allocator: Allocator, test_vector: *const PVMFixture) !PVM {
    var pvm = try PVM.init(allocator, test_vector.program, test_vector.initial_gas);
    errdefer pvm.deinit();

    // Set initial registers
    @memcpy(&pvm.registers, &test_vector.initial_regs);

    // Set initial page map
    try pvm.setPageMap(@ptrCast(test_vector.initial_page_map));

    // Set initial memory
    for (test_vector.initial_memory) |chunk| {
        try pvm.pushMemory(chunk.address, chunk.contents);
    }

    // Set initial PC
    pvm.pc = test_vector.initial_pc;

    return pvm;
}

pub fn runTestFixture(allocator: Allocator, test_vector: *const PVMFixture) !bool {
    var pvm = try initPVMFromTestVector(allocator, test_vector);
    defer pvm.deinit();

    const result = pvm.run();

    // Check if the execution status matches the expected status
    var status_matches: bool = undefined;
    if (result) {
        std.debug.print("Result: {any}\n", .{result});
        std.debug.print("Expected status: {any}\n", .{test_vector.expected_status});
        status_matches = test_vector.expected_status == .halt;
    } else |err| {
        status_matches = switch (err) {
            error.PANIC => test_vector.expected_status == .trap,
            error.OUT_OF_GAS => test_vector.expected_status == .trap,
            error.MAX_ITERATIONS_REACHED => false,
            else => false,
        };
    }

    if (!status_matches) {
        std.debug.print("Status mismatch: expected {any}, got {any}\n", .{
            test_vector.expected_status,
            result,
        });
        return false;
    }

    // Check if registers match
    if (!std.mem.eql(u32, &pvm.registers, &test_vector.expected_regs)) {
        std.debug.print("Register mismatch\n", .{});
        return false;
    }

    // Check if PC matches
    if (pvm.pc != test_vector.expected_pc) {
        std.debug.print("PC mismatch: expected {}, got {}\n", .{ test_vector.expected_pc, pvm.pc });
        return false;
    }

    // Check if memory matches
    for (test_vector.expected_memory) |_| {
        // we need to match if we have the same chunk
        // in the pvm

        // we neeed to see
    }

    // Check if gas matches
    if (pvm.gas != test_vector.expected_gas) {
        std.debug.print("Gas mismatch: expected {}, got {}\n", .{ test_vector.expected_gas, pvm.gas });
        return false;
    }

    return true;
}

pub fn runTestFixtureFromPath(allocator: Allocator, path: []const u8) !bool {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const vector = try PMVLib.PVMTestVector.build_from(allocator, path);
    defer vector.deinit();

    const fixture = try PVMFixture.from_vector(allocator, &vector.value);

    return runTestFixture(allocator, &fixture);
}
