const std = @import("std");
const pvmlib = @import("pvm.zig");

const testing = std.testing;

comptime {
    // TODO: disabled for now, need to reuild host_call bytecode
    // using a 64bit enabled polkavm tool and waiting for test vectors
    // _ = @import("pvm_test/test_vectors.zig");
    // _ = @import("pvm_test/host_call.zig");
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
        121, 119, 255, //
        81, 7, 12, //
        100, 138, //
        170, 152, 8, //
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

    var pvm = try pvmlib.PVM.init(allocator, &raw_program, std.math.maxInt(u32));
    defer pvm.deinit();

    pvm.registers[0] = 4294901760;
    pvm.registers[7] = 9;

    // std.debug.print("Program: {any}\n", .{pvm.program});

    const status = pvmlib.PVM.Status.fromResult(pvm.run(), pvm.error_data);

    if (status != .halt) {
        std.debug.print("Expected .halt got {any}\n", .{status});
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

fn printProgramDecompilation(allocator: std.mem.Allocator, path: []const u8) !void {
    const PMVLib = @import("./jamtestvectors/pvm.zig");

    const vector = try PMVLib.PVMTestVector.build_from(allocator, path);
    defer vector.deinit();

    var pvm = try pvmlib.PVM.init(allocator, vector.value.program, std.math.maxInt(u32));
    defer pvm.deinit();

    std.debug.print("Program decompilation:\n", .{});
    try pvm.decompilePrint();
}
