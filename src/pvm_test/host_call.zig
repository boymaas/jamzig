const std = @import("std");
const pvmlib = @import("../pvm.zig");

fn testHostCall(gas: *i64, registers: *[13]u64, page_map: []pvmlib.PVM.PageMap) pvmlib.PMVHostCallResult {
    _ = page_map;
    _ = gas;
    registers[0] += 1;
    return .play;
}

test "pvm:ecalli:host_call" {
    const allocator = std.testing.allocator;

    const ecalli: []const u8 = @embedFile("pvm_test/fixtures/jampvm/ecalli.jampvm");

    var pvm = try pvmlib.PVM.init(allocator, ecalli, 1000);
    defer pvm.deinit();

    try pvm.registerHostCall(0, testHostCall);

    pvm.registers[0] = 42;

    const status = pvm.run();
    try std.testing.expectEqual(pvmlib.PVM.Status.panic, status);
    try std.testing.expectEqual(@as(u32, 43), pvm.registers[0]);
}

test "pvm:ecalli:host_call:add" {
    const allocator = std.testing.allocator;

    const ecalli_and_add: []const u8 = @embedFile("pvm_test/fixtures/jampvm/ecalli_and_add.jampvm");

    var pvm = try pvmlib.PVM.init(allocator, ecalli_and_add, 1000);
    defer pvm.deinit();

    try pvm.registerHostCall(0, testHostCall);

    pvm.registers[0] = 42;

    const status = pvm.run();

    try std.testing.expectEqual(pvmlib.PVM.Status.panic, status);
    try std.testing.expectEqual(@as(u32, 44), pvm.registers[0]);
}
