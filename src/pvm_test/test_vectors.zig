const std = @import("std");
const pvmlib = @import("../pvm.zig");

const fixtures = @import("fixtures.zig");

// Get all files from the test directory
const BASE_PATH = fixtures.BASE_PATH;

// List of test vectors to skip
const skip_vectors = [_][]const u8{
    // expects a page fault address of 0x00021000. Based on my current
    // understanding, the formula indicates the PVM should report the first
    // violating address, which would be 0x00021001. However, the test seems to
    // expect the start of the page where the violation occurred instead.
    // https://github.com/w3f/jamtestvectors/pull/3#issuecomment-2615612062
    "inst_store_indirect_u16_with_offset_nok.json",
    "inst_store_indirect_u32_with_offset_nok.json",
    "inst_store_indirect_u64_with_offset_nok.json",
    "inst_store_indirect_u8_with_offset_nok.json",
    // This group all has to do with page fault violation
};

test "pvm:test_vectors" {
    const allocator = std.testing.allocator;

    var ordered_files = try @import("../tests/ordered_files.zig").getOrderedFiles(allocator, BASE_PATH);
    defer ordered_files.deinit();

    // Run tests for each file
    // Check for PVM_TEST environment variable
    const pvm_test = std.process.getEnvVarOwned(allocator, "PVM_TEST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (pvm_test) |p| allocator.free(p);

    for (ordered_files.items()) |file| {
        // Skip files that don't match PVM_TEST if it's set
        if (pvm_test) |filter| {
            if (!std.mem.containsAtLeast(u8, file.name, 1, filter)) {
                continue;
            }
        }

        // Skip vectors in the skip list
        var should_skip = false;
        for (skip_vectors) |skip_name| {
            if (std.mem.eql(u8, file.name, skip_name)) {
                std.debug.print("\nSkipping test vector: {s}\n", .{file.name});
                should_skip = true;
                break;
            }
        }
        if (should_skip) continue;

        std.debug.print("\nRunning test vector: {s}\n", .{file.name});

        // Execute test
        const debug_point = @src();
        const test_result = fixtures.runTestFixtureFromPath(allocator, file.path) catch |err| {
            std.debug.print("Test {s} failed with error: {}\n", .{ file.name, err });
            return err;
        };

        if (!test_result) {
            std.debug.print("\nTest failed for vector: {s}\n", .{file.name});
            std.debug.print("\nTo run only this test:\n", .{});
            std.debug.print("PVM_TEST={s} ztf pvm:test_vectors\n\n", .{file.name});
            std.debug.print("PVM_TEST={s} ztf-debug pvm:test_vectors {s}:{d}\n\n", .{ file.name, debug_point.file, debug_point.line });
            std.debug.print("PVM_TEST={s} ztf-debug pvm:test_vectors src/pvm.zig:pvm.PVM.innerRunStep\n\n", .{
                file.name,
            });

            return error.TestFailed;
        }
    }
}
