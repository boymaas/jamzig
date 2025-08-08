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

// Structures to track test failures
const TestFailure = struct {
    name: []const u8,
    error_name: []const u8,
};

pub fn main() !void {
    const args = std.process.argsAlloc(fba.allocator()) catch
        @panic("unable to parse command line args");

    var progress = false;
    var nocapture = false;
    var exit_on_fail = false;
    var log_progress = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "--progress")) {
            progress = true;
        } else if (std.mem.eql(u8, arg, "--nocapture")) {
            nocapture = true;
        } else if (std.mem.eql(u8, arg, "--exit-on-fail")) {
            exit_on_fail = true;
        } else if (std.mem.eql(u8, arg, "--log-progress")) {
            log_progress = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Test runner options:\n", .{});
            std.debug.print("  --verbose, --progress  Show progress for each test\n", .{});
            std.debug.print("  --nocapture            Don't capture stderr output\n", .{});
            std.debug.print("  --exit-on-fail         Exit immediately on first test failure\n", .{});
            std.debug.print("  --log-progress         Log test progress to test_progress.log file\n", .{});
            std.debug.print("  --help, -h             Show this help message\n", .{});
            return;
        } else {
            std.debug.print("Error: unrecognized command line argument '{s}'\n", .{arg});
            std.debug.print("Use --help to see available options\n", .{});
            return;
        }
    }

    fba.reset();

    try mainTerminal(progress, nocapture, exit_on_fail, log_progress);
}

fn redirectStderr() !posix.fd_t {
    const old_fd = try posix.dup(posix.STDERR_FILENO);
    // Open /dev/null for writing
    const dev_null = try posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    try posix.dup2(dev_null, posix.STDERR_FILENO);
    posix.close(dev_null);
    return old_fd;
}

fn restoreStderr(old_fd: posix.fd_t) !void {
    try posix.dup2(old_fd, posix.STDERR_FILENO);
    posix.close(old_fd);
}

fn mainTerminal(progress: bool, nocapture: bool, exit_on_fail: bool, log_progress: bool) !void {
    @disableInstrumentation();
    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;

    var failed_tests = ArrayList(TestFailure).init(fba.allocator());
    defer failed_tests.deinit();

    var leaked_tests = ArrayList([]const u8).init(fba.allocator());
    defer leaked_tests.deinit();

    // Open progress log file if requested
    var progress_file: ?std.fs.File = null;
    defer if (progress_file) |file| file.close();
    
    if (log_progress) {
        progress_file = try std.fs.cwd().createFile("test_progress.log", .{});
        const timestamp = std.time.timestamp();
        try progress_file.?.writer().print("Test run started at timestamp: {d}\n", .{timestamp});
        try progress_file.?.writer().print("Total tests to run: {d}\n\n", .{test_fn_list.len});
    }

    var leaks: usize = 0;
    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
                leaked_tests.append(test_fn.name) catch {};
            }
        }
        testing.log_level = .warn;

        // Log test start to progress file
        if (progress_file) |file| {
            file.writer().print("[{d}/{d}] Starting test: {s}\n", .{ i + 1, test_fn_list.len, test_fn.name }) catch {};
        }

        if (progress) {
            std.debug.print("\x1b[1;36m{d}/{d}\x1b[0m {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        }

        // Redirect stderr if not in verbose mode and nocapture is false
        const old_fd = if (!nocapture)
            try redirectStderr()
        else
            undefined;

        const start_time = std.time.nanoTimestamp();
        const result = test_fn.func();
        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Restore stderr if it was redirected
        if (!nocapture) {
            try restoreStderr(old_fd);
        }

        if (result) |_| {
            ok_count += 1;
            if (progress) std.debug.print("\x1b[1;32mOK\x1b[0m\n", .{});
            
            // Log test success to progress file
            if (progress_file) |file| {
                file.writer().print("[{d}/{d}] Test PASSED: {s} (duration: {d:.3}ms)\n", .{ 
                    i + 1, test_fn_list.len, test_fn.name, duration_ms 
                }) catch {};
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                if (progress) {
                    std.debug.print("\x1b[1;33m{d}/{d}\x1b[0m {s}...\x1b[1;33mSKIP\x1b[0m\n", .{ i + 1, test_fn_list.len, test_fn.name });
                }
                
                // Log test skip to progress file
                if (progress_file) |file| {
                    file.writer().print("[{d}/{d}] Test SKIPPED: {s}\n", .{ 
                        i + 1, test_fn_list.len, test_fn.name 
                    }) catch {};
                }
            },
            else => {
                fail_count += 1;
                try failed_tests.append(.{
                    .name = test_fn.name,
                    .error_name = @errorName(err),
                });

                if (progress) {
                    std.debug.print("\x1b[1;31m{d}/{d}\x1b[0m {s}...\x1b[1;31mFAIL\x1b[0m (\x1b[1;31m{s}\x1b[0m)\n", .{
                        i + 1, test_fn_list.len, test_fn.name, @errorName(err),
                    });
                }
                
                // Log test failure to progress file
                if (progress_file) |file| {
                    file.writer().print("[{d}/{d}] Test FAILED: {s} (error: {s}, duration: {d:.3}ms)\n", .{ 
                        i + 1, test_fn_list.len, test_fn.name, @errorName(err), duration_ms 
                    }) catch {};
                }

                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }

                // Exit immediately on first test failure if flag is set
                if (exit_on_fail) {
                    std.process.exit(1);
                }
            },
        }
    }

    // Write summary to progress file
    if (progress_file) |file| {
        file.writer().print("\n========== TEST RUN SUMMARY ==========\n", .{}) catch {};
        file.writer().print("Total tests: {d}\n", .{test_fn_list.len}) catch {};
        file.writer().print("Passed: {d}\n", .{ok_count}) catch {};
        file.writer().print("Failed: {d}\n", .{fail_count}) catch {};
        file.writer().print("Skipped: {d}\n", .{skip_count}) catch {};
        
        if (failed_tests.items.len > 0) {
            file.writer().print("\nFailed Tests:\n", .{}) catch {};
            for (failed_tests.items) |failure| {
                file.writer().print("  - {s} (error: {s})\n", .{ failure.name, failure.error_name }) catch {};
            }
        }
        
        if (leaks != 0) {
            file.writer().print("\nMemory Leaks Detected in {d} tests:\n", .{leaks}) catch {};
            for (leaked_tests.items) |test_name| {
                file.writer().print("  - {s}\n", .{test_name}) catch {};
            }
        }
        
        const end_timestamp = std.time.timestamp();
        file.writer().print("\nTest run completed at timestamp: {d}\n", .{end_timestamp}) catch {};
    }

    if (progress) {
        if (ok_count == test_fn_list.len) {
            std.debug.print("\x1b[1;32mAll {d} tests passed.\x1b[0m\n", .{ok_count});
        } else {
            std.debug.print("\x1b[1;33m{d} passed\x1b[0m; \x1b[1;33m{d} skipped\x1b[0m; \x1b[1;31m{d} failed\x1b[0m.\n", .{ ok_count, skip_count, fail_count });

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
