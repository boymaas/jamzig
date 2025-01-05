const std = @import("std");
const safrole_adaptor = @import("adaptor.zig");
const fixtures = @import("fixtures.zig");
const assert = std.debug.assert;
const Params = @import("../jam_params.zig").Params;

pub fn runSafroleTest(
    comptime params: Params,
    allocator: std.mem.Allocator,
    bin_file_path: []const u8,
) !void {
    var fixture = try fixtures.buildFixtures(params, allocator, bin_file_path);
    defer fixture.deinit();

    var actual_result = try safrole_adaptor.transition(
        params,
        allocator,
        fixture.pre_state,
        fixture.input,
    );
    defer actual_result.deinit(allocator);

    // Compare outputs
    fixture.expectOutput(actual_result.output) catch |err| {
        std.debug.print("\n❌ Output mismatch for {s}\n", .{bin_file_path});
        // std.debug.print("Expected output: {any}\n", .{fixture.output});
        // std.debug.print("Actual output: {any}\n", .{actual_result.output});
        std.debug.print("Error: {any}\n", .{err});
        std.debug.print("\n\n", .{});
        return err;
    };

    // Compare post states if available
    if (actual_result.state) |state| {
        fixture.expectPostState(&state) catch |err| {
            std.debug.print("\n❌ Post-state mismatch for {s}\n", .{bin_file_path});
            std.debug.print("\n\x1b[33m↓ Expected State Changes Below ↓\x1b[0m\n", .{});
            try fixture.diffStatesAndPrint();
            std.debug.print("Error: {any}\n", .{err});
            return err;
        };
    }

    // Print success message
    std.debug.print("\n✅ Test passed: {s}\n", .{bin_file_path});
}

pub fn runSafroleTestDir(
    comptime params: Params,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) !void {
    const ordered_files = @import("../tests/ordered_files.zig");

    var file_list = try ordered_files.getOrderedFiles(allocator, dir_path);
    defer file_list.deinit();

    var failed_tests = std.ArrayList([]const u8).init(allocator);
    defer failed_tests.deinit();

    for (file_list.items()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;

        try runSafroleTest(params, allocator, entry.path);
    }
}

test "tiny: Run tiny safrole tests" {
    try runSafroleTestDir(
        @import("../jam_params.zig").TINY_PARAMS,
        std.testing.allocator,
        "src/jamtestvectors/data/safrole/tiny",
    );
}

test "full: Run full safrole tests" {
    try runSafroleTestDir(
        @import("../jam_params.zig").FULL_PARAMS,
        std.testing.allocator,
        "src/jamtestvectors/data/safrole/full",
    );
}
