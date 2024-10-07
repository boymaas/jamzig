const std = @import("std");
const pvmlib = @import("pvm.zig");

const fixtures = @import("pvm_test/fixtures.zig");

test "pvm:simple" {
    const allocator = std.testing.allocator;

    // -----------------------[0, 0, 33, 4, 8, 1, 4, 9, 1, 5, 3, 0, 2, 119, 255, 7, 7, 12, 82, 138, 8, 152, 8, 82, 169, 5, 243, 82, 135, 4, 8, 4, 9, 17, 19, 0, 73, 147, 82, 213, 254]
    // const raw_program = [_]u8{ 0, 0, 33, 4, 8, 1, 4, 9, 1, 5, 3, 0, 2, 119, 255, 7, 7, 12, 82, 138, 8, 152, 8, 82, 169, 5, 243, 82, 135, 4, 8, 4, 9, 17, 19, 0, 73, 147, 82, 213, 254 };

    const raw_program = [_]u8{
        0x00, 0x00, 0x21, 0x04, 0x08, 0x01, 0x04, 0x09, 0x01, 0x05, 0x03, 0x00, //
        0x02, 0x77, 0xff, 0x07, 0x07, 0x0c, 0x52, 0x8a, 0x08, 0x98, 0x08, 0x52, //
        0xa9, 0x05, 0xf3, 0x52, 0x87, 0x04, 0x08, 0x04, 0x09, 0x11, 0x13, 0x00, //
        0x49, 0x93, 0x52, 0xd5, 0xfe,
    };

    var pvm = try pvmlib.PVM.init(allocator, &raw_program, std.math.maxInt(u32));
    defer pvm.deinit();

    pvm.registers[0] = 4294901760;
    pvm.registers[7] = 9;

    // std.debug.print("Program: {any}\n", .{pvm.program});

    const result = pvm.run();

    if (result != .halt) {
        std.debug.print("Expected .halt got {any}\n", .{result});
        return error.TestFailed;
    }

    // Check final register values
    const expected_registers = [_]u32{ 4294901760, 0, 0, 0, 0, 0, 0, 55, 0, 0, 34, 0, 0 };

    for (expected_registers, 0..) |expected, i| {
        if (pvm.registers[i] != expected) {
            std.debug.print("Register r{} mismatch. Expected: {}, Got: {}\n", .{ i, expected, pvm.registers[i] });
            return error.TestFailed;
        }
    }
}

fn testHostCall(gas: *i64, registers: *[13]u32, page_map: []pvmlib.PVM.PageMap) pvmlib.PMVHostCallResult {
    _ = page_map;
    _ = gas;
    // std.debug.print("Host call\n", .{});
    // Simple host call that adds 1 to the first register
    registers[0] += 1;
    return .play;
}

test "pvm:ecalli:host_call" {
    const allocator = std.testing.allocator;

    // Create a simple program that makes a host call
    const ecalli: []const u8 = @embedFile("pvm_test/fixtures/jampvm/ecalli.jampvm");

    var pvm = try pvmlib.PVM.init(allocator, ecalli, 1000);
    defer pvm.deinit();

    // See the program
    // try pvm.decompilePrint();

    // Register the host call
    try pvm.registerHostCall(0, testHostCall);

    // Set up initial register value
    pvm.registers[0] = 42;

    // Run the program
    const status = pvm.run();

    // Check the results
    try std.testing.expectEqual(pvmlib.PVM.Status.panic, status);
    try std.testing.expectEqual(@as(u32, 43), pvm.registers[0]);
}

test "pvm:ecalli:host_call:add" {
    const allocator = std.testing.allocator;

    // Create a simple program that makes a host call
    // and afterwards updates the register some more to test continuation
    const ecalli_and_add: []const u8 = @embedFile("pvm_test/fixtures/jampvm/ecalli_and_add.jampvm");

    var pvm = try pvmlib.PVM.init(allocator, ecalli_and_add, 1000);
    defer pvm.deinit();

    // See the program
    // try pvm.decompilePrint();

    // Register the host call
    try pvm.registerHostCall(0, testHostCall);

    // Set up initial register value
    pvm.registers[0] = 42;

    // Run the program, this does the hostcall and then adds 1 to the register
    const status = pvm.run();

    // Check the results
    try std.testing.expectEqual(pvmlib.PVM.Status.panic, status);
    try std.testing.expectEqual(@as(u32, 44), pvm.registers[0]);
}

test "pvm:inst_add" {
    const allocator = std.testing.allocator;
    const test_result = try fixtures.runTestFixtureFromPath(allocator, "src/tests/vectors/pvm/pvm/pvm/programs/inst_add.json");
    try std.testing.expect(test_result);
}

test "pvm:test_vectors" {
    const TEST_VECTORS = @import("./pvm_test/vectors.zig").TEST_VECTORS;
    const allocator = std.testing.allocator;

    for (TEST_VECTORS) |test_vector| {
        std.debug.print("Running test vector: {s}\n", .{test_vector});
        const path = try std.fmt.allocPrint(allocator, "src/tests/vectors/pvm/pvm/pvm/programs/{s}", .{test_vector});
        defer allocator.free(path);

        // try printProgramDecompilation(allocator, path);
        const test_result = fixtures.runTestFixtureFromPath(allocator, path) catch |err| {
            std.debug.print("Test {s} failed with error: {}\n", .{ test_vector, err });
            return err;
        };

        if (!test_result) {
            std.debug.print("Test failed for vector: {s}\n", .{test_vector});
            return error.TestFailed;
        }
    }
}

fn printProgramDecompilation(allocator: std.mem.Allocator, path: []const u8) !void {
    const PMVLib = @import("./tests/vectors/libs/pvm.zig");

    const vector = try PMVLib.PVMTestVector.build_from(allocator, path);
    defer vector.deinit();

    var pvm = try pvmlib.PVM.init(allocator, vector.value.program, std.math.maxInt(u32));
    defer pvm.deinit();

    std.debug.print("Program decompilation:\n", .{});
    try pvm.decompilePrint();
}
