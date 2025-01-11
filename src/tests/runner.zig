const std = @import("std");
const io = std.io;
const testing = std.testing;
const assert = std.debug.assert;
const posix = std.posix;
const ArrayList = std.ArrayList;

const builtin = @import("builtin");

var log_err_count: usize = 0;
var fba_buffer: [8192]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);

// Structures to track test failures and leaks
const TestFailure = struct {
    name: []const u8,
    error_name: []const u8,
};

pub fn main() !void {
    const args = std.process.argsAlloc(fba.allocator()) catch
        @panic("unable to parse command line args");

    var progress = false;
    var nocapture = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            progress = true;
        } else if (std.mem.eql(u8, arg, "--nocapture")) {
            nocapture = true;
        } else {
            std.debug.print("Error: unrecognized command line argument '{s}'\n", .{arg});
            return;
        }
    }

    fba.reset();

    try mainTerminal(progress, nocapture);
}

fn mainTerminal(progress: bool, nocapture: bool) !void {
    @disableInstrumentation();
    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;

    // Create arrays to store failed and leaking test names
    var failed_tests = ArrayList(TestFailure).init(fba.allocator());
    defer failed_tests.deinit();

    var leaked_tests = ArrayList([]const u8).init(fba.allocator());
    defer leaked_tests.deinit();

    var leaks: usize = 0;
    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
                // Store the name of the leaking test
                leaked_tests.append(test_fn.name) catch {};
            }
        }
        testing.log_level = .warn;

        if (progress) {
            std.debug.print("\x1b[1;36m{d}/{d}\x1b[0m {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        }

        _ = nocapture;

        const result = test_fn.func();

        if (result) |_| {
            ok_count += 1;
            if (progress) std.debug.print("\x1b[1;32mOK\x1b[0m\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                if (progress) {
                    std.debug.print("\x1b[1;33m{d}/{d}\x1b[0m {s}...\x1b[1;33mSKIP\x1b[0m\n", .{ i + 1, test_fn_list.len, test_fn.name });
                }
            },
            else => {
                fail_count += 1;
                // Store the failed test information
                failed_tests.append(.{
                    .name = test_fn.name,
                    .error_name = @errorName(err),
                }) catch {};

                if (progress) {
                    std.debug.print("\x1b[1;31m{d}/{d}\x1b[0m {s}...\x1b[1;31mFAIL\x1b[0m (\x1b[1;31m{s}\x1b[0m)\n", .{
                        i + 1, test_fn_list.len, test_fn.name, @errorName(err),
                    });
                }
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            },
        }
    }

    if (progress) {
        if (ok_count == test_fn_list.len) {
            std.debug.print("\x1b[1;32mAll {d} tests passed.\x1b[0m\n", .{ok_count});
        } else {
            std.debug.print("\x1b[1;33m{d} passed\x1b[0m; \x1b[1;33m{d} skipped\x1b[0m; \x1b[1;31m{d} failed\x1b[0m.\n", .{ ok_count, skip_count, fail_count });

            // Print failed tests summary
            if (failed_tests.items.len > 0) {
                std.debug.print("\n\x1b[1;31mFailed Tests:\x1b[0m\n", .{});
                for (failed_tests.items) |failure| {
                    std.debug.print("  - {s} (error: {s})\n", .{ failure.name, failure.error_name });
                }
            }
        }

        if (log_err_count != 0) {
            std.debug.print("\x1b[1;31m{d} errors were logged.\x1b[0m\n", .{log_err_count});
        }

        // Print memory leak summary
        if (leaks != 0) {
            std.debug.print("\x1b[1;31m{d} tests leaked memory:\x1b[0m\n", .{leaks});
            for (leaked_tests.items) |test_name| {
                std.debug.print("  - {s}\n", .{test_name});
            }
        }
    }

    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}
