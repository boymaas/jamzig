const std = @import("std");
const pvmlib = @import("pvm.zig");

const testing = std.testing;

comptime {
    _ = @import("pvm_test/test_vectors.zig");
    // TODO: disabled for now, need to reuild host_call bytecode
    // using a 64bit enabled polkavm tool and waiting for test vectors
    // _ = @import("pvm_test/host_call.zig");
}

test "pvm:jamduna_service_code:machine_invocation" {
    const allocator = std.testing.allocator;

    const program_code = @embedFile("pvm_test/fixtures/jam_duna_service_code.pvm");

    var result = try pvmlib.invoke.machineInvocation(
        allocator,
        program_code,
        5,
        std.math.maxInt(u32),
        &[_]u8{0} ** 20,
        .{},
    );
    defer result.deinit(allocator);

    std.debug.print("{}", .{result});
}

test "pvm:jamduna_service_code" {
    const allocator = std.testing.allocator;
    const raw_program = @embedFile("pvm_test/fixtures/jam_duna_service_code.pvm");

    var execution_context = try pvmlib.PVM.ExecutionContext.initStandardProgramCodeFormat(
        allocator,
        raw_program,
        &[_]u8{3} ** 32,
        std.math.maxInt(u32),
    );
    defer execution_context.deinit(allocator);

    try execution_context.debugProgram(std.io.getStdErr().writer());

    // execution_context.clearRegisters();

    execution_context.pc = 5; // for accumulate
    const status = try pvmlib.PVM.basicInvocation(&execution_context);

    if (status.terminal != .halt) {
        std.debug.print("Expected .halt got {any}\n", .{status});
    }
}

test "pvm:simple" {
    const allocator = std.testing.allocator;

    const raw_program = [_]u8{
        // Header
        0, 0, 33,
        // Code
        51, 8, 1, //
        51, 9, 1, //
        40, 3, //
        0, //
        149, 119, 255, //
        81, 7, 12, //
        100, 138, //
        200, 152, 8, //
        100, 169, //
        40, 243, //
        100, 135, //
        51, 8, //
        51, 9, //
        1, //
        50, 0, //

        // Mask
        73, 147, 82, 213, 0, //
    };

    var execution_context = try pvmlib.PVM.ExecutionContext.initSimple(
        allocator,
        &raw_program,
        1024,
        4,
        std.math.maxInt(u32),
    );
    defer execution_context.deinit(allocator);

    execution_context.clearRegisters();
    execution_context.registers[0] = 4294901760;
    execution_context.registers[7] = 9;

    const status = try pvmlib.PVM.basicInvocation(&execution_context);

    if (status.terminal != .halt) {
        std.debug.print("Expected .halt got {any}\n", .{status});
    }

    // Check final register values
    const expected_registers = [_]u32{ 4294901760, 0, 0, 0, 0, 0, 0, 55, 0, 0, 34, 0, 0 };

    for (expected_registers, 0..) |expected, i| {
        if (execution_context.registers[i] != expected) {
            std.debug.print("Register r{} mismatch. Expected: {}, Got: {}\n", .{ i, expected, execution_context.registers[i] });
            return error.TestFailed;
        }
    }
}

test "pvm:game_of_life" {
    const allocator = std.testing.allocator;

    const raw_program = [_]u8{
        0,   0,   129, 23,  30,  1,   3,   255, 0,   30,  1,   11,  255, 0,   30,  1,   19,  255, 0,   30,  1,   18,  255, 0,   30,  1,   9,   255, 0,   40,
        233, 0,   51,  1,   255, 1,   149, 17,  1,   81,  17,  8,   223, 0,   51,  2,   255, 1,   149, 34,  1,   81,  18,  8,   241, 150, 19,  8,   200, 35,
        3,   40,  47,  149, 51,  128, 0,   124, 52,  132, 68,  1,   82,  20,  1,   14,  83,  21,  2,   25,  86,  21,  3,   21,  40,  8,   81,  21,  3,   6,
        40,  11,  149, 51,  128, 70,  3,   255, 0,   40,  205, 149, 51,  128, 70,  3,   40,  198, 51,  5,   100, 52,  51,  8,   64,  149, 68,  255, 205, 132,
        7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101, 5,   149, 68,  2,   205, 132, 7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101,
        5,   149, 68,  247, 205, 132, 7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101, 5,   149, 68,  16,  205, 132, 7,   149, 119, 128, 0,   124,
        118, 132, 102, 1,   200, 101, 5,   149, 68,  1,   205, 132, 7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101, 5,   149, 68,  254, 205, 132,
        7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101, 5,   149, 68,  240, 205, 132, 7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101,
        5,   149, 68,  2,   205, 132, 7,   149, 119, 128, 0,   124, 118, 132, 102, 1,   200, 101, 5,   40,  60,  255, 51,  1,   1,   149, 19,  128, 0,   128,
        18,  122, 50,  149, 17,  4,   81,  17,  64,  12,  255, 40,  240, 33,  132, 16,  146, 9,   153, 72,  138, 18,  17,  69,  137, 82,  149, 36,  74,  146,
        40,  73,  162, 36,  137, 146, 36,  74,  146, 40,  73,  162, 36,  137, 146, 52,  42,  33,
    };

    var execution_context = try pvmlib.PVM.ExecutionContext.initSimple(allocator, &raw_program, 1024, 4, std.math.maxInt(u32));
    defer execution_context.deinit(allocator);

    // const status = try pvmlib.PVM.execute(&execution_context);
    //
    // if (status != .halt) {
    //     std.debug.print("Expected .halt got {any}\n", .{status});
    // }
}

fn printProgramDecompilation(allocator: std.mem.Allocator, path: []const u8) !void {
    const PMVLib = @import("./jamtestvectors/pvm.zig");

    const vector = try PMVLib.PVMTestVector.build_from(allocator, path);
    defer vector.deinit();

    var pvm = try pvmlib.PVM.init(allocator, vector.value.program, std.math.maxInt(u32));
    defer pvm.deinit();

    std.debug.print("Program decompilation:\n", .{});
    try pvm.decompilePrint();
}
