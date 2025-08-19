const std = @import("std");
const testing = std.testing;

const jam_params = @import("jam_params.zig");
const trace_runner = @import("trace_runner/runner.zig");
const parsers = @import("trace_runner/parsers.zig");
const messages = @import("fuzz_protocol/messages.zig");
const version = @import("version.zig");

// Use FUZZ_PARAMS for consistency with fuzz protocol testing
const FUZZ_PARAMS = jam_params.TINY_PARAMS;
const RunConfig = trace_runner.RunConfig;

// Skipped tests configuration
const SkippedTest = struct {
    id: []const u8,
    reason: []const u8,
};

const SKIPPED_TESTS = [_]SkippedTest{
    .{
        .id = "1754982087",
        .reason = "Invalid test: service ID generation used LE instead of varint (B.10)",
    },
};

test "jam-conformance:traces" {
    const allocator = testing.allocator;

    // Check for environment variable
    const trace_timestamp = std.process.getEnvVarOwned(allocator, "JAM_CONFORMANCE_ARCHIVE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("Skipping traces test. Set JAM_CONFORMANCE_ARCHIVE=<timestamp> to run a specific trace\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(trace_timestamp);

    // Check if this test is skipped
    if (isSkippedTest(trace_timestamp)) |reason| {
        std.debug.print("\n⏭️  SKIPPED: Test {s} is known to be invalid\n", .{trace_timestamp});
        std.debug.print("   Reason: {s}\n\n", .{reason});
        return;
    }

    // Build path to specific trace directory
    const traces_base = try buildTracesPath(allocator);
    defer allocator.free(traces_base);

    const specific_trace_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ traces_base, trace_timestamp });
    defer allocator.free(specific_trace_path);

    // Check if directory exists
    var dir = std.fs.cwd().openDir(specific_trace_path, .{}) catch |err| {
        std.debug.print("Error: Trace directory not found: {s}\n", .{specific_trace_path});
        return err;
    };
    dir.close();

    std.debug.print("Running trace test for: {s}\n", .{trace_timestamp});

    // Run test for the specific directory only
    const w3f_loader = parsers.w3f.Loader(FUZZ_PARAMS){};
    const loader = w3f_loader.loader();

    var run_result = try trace_runner.runTracesInDir(
        FUZZ_PARAMS,
        loader,
        allocator,
        specific_trace_path,
        RunConfig{ .mode = .CONTINOUS_MODE, .quiet = false },
    );
    defer run_result.deinit(allocator);
}

test "jam-conformance:summary" {
    const allocator = testing.allocator;
    const traces_path = try buildTracesPath(allocator);
    defer allocator.free(traces_path);

    try runTraceSummary(allocator, traces_path);
}

// -- Helper Functions --

fn isSkippedTest(id: []const u8) ?[]const u8 {
    for (SKIPPED_TESTS) |skipped| {
        if (std.mem.eql(u8, skipped.id, id)) {
            return skipped.reason;
        }
    }
    return null;
}

fn buildTracesPath(allocator: std.mem.Allocator) ![]u8 {
    const graypaper = version.GRAYPAPER_VERSION;
    const version_str = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ graypaper.major, graypaper.minor, graypaper.patch });
    defer allocator.free(version_str);

    return try std.fmt.allocPrint(allocator, "src/jam-conformance/fuzz-reports/{s}/traces", .{version_str});
}

fn runTraceSummary(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const directories = try discoverReportDirectories(allocator, base_path);
    defer {
        for (directories.items) |dir| {
            allocator.free(dir);
        }
        directories.deinit();
    }

    std.debug.print("\n=== Conformance Summary: {s} ===\n", .{base_path});
    std.debug.print("Found {d} report directories\n", .{directories.items.len});

    if (directories.items.len == 0) {
        std.debug.print("No report directories found in {s}\n", .{base_path});
        return;
    }

    // Create W3F loader for the traces
    const w3f_loader = parsers.w3f.Loader(FUZZ_PARAMS){};
    const loader = w3f_loader.loader();

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    // Track failures and no-op blocks for summary
    var failures = std.ArrayList(struct {
        id: []u8,
        err: anyerror,
    }).init(allocator);
    defer {
        for (failures.items) |failure| {
            allocator.free(failure.id);
        }
        failures.deinit();
    }
    
    var no_op_blocks = std.ArrayList(struct {
        id: []u8,
        exceptions: []const u8,
    }).init(allocator);
    defer {
        for (no_op_blocks.items) |block| {
            allocator.free(block.id);
            allocator.free(block.exceptions);
        }
        no_op_blocks.deinit();
    }

    var skipped_tests = std.ArrayList(struct {
        id: []u8,
        reason: []const u8,
    }).init(allocator);
    defer {
        for (skipped_tests.items) |skipped_test| {
            allocator.free(skipped_test.id);
        }
        skipped_tests.deinit();
    }

    // Run traces in each directory and track results
    for (directories.items, 1..) |dir, idx| {
        // Extract just the report ID from the path
        const last_slash = std.mem.lastIndexOf(u8, dir, "/") orelse 0;
        const report_id = if (last_slash > 0) dir[last_slash + 1 ..] else dir;

        // Check if this test is skipped
        if (isSkippedTest(report_id)) |reason| {
            std.debug.print("[{d:3}/{d:3}] {s}: ⏭️  SKIPPED ({s})\n", .{ idx, directories.items.len, report_id, reason });
            skipped += 1;
            const id_copy = try allocator.dupe(u8, report_id);
            try skipped_tests.append(.{ .id = id_copy, .reason = reason });
            continue;
        }

        // Try to run traces, catch and record any errors
        var run_result = trace_runner.runTracesInDir(
            FUZZ_PARAMS,
            loader,
            allocator,
            dir,
            RunConfig{ .mode = .CONTINOUS_MODE, .quiet = true },
        ) catch |err| {
            std.debug.print("[{d:3}/{d:3}] {s}: ❌ {s}\n", .{ idx, directories.items.len, report_id, @errorName(err) });
            failed += 1;
            const id_copy = try allocator.dupe(u8, report_id);
            try failures.append(.{ .id = id_copy, .err = err });
            continue;
        };
        defer run_result.deinit(allocator);

        // Track no-op blocks if any
        if (run_result.had_no_op_blocks) {
            const id_copy = try allocator.dupe(u8, report_id);
            const exceptions_copy = try allocator.dupe(u8, run_result.no_op_exceptions);
            try no_op_blocks.append(.{ .id = id_copy, .exceptions = exceptions_copy });
            std.debug.print("[{d:3}/{d:3}] {s}: ✅ PASS (no-op block: {s})\n", .{ 
                idx, directories.items.len, report_id, run_result.no_op_exceptions 
            });
        } else {
            std.debug.print("[{d:3}/{d:3}] {s}: ✅ PASS\n", .{ idx, directories.items.len, report_id });
        }
        passed += 1;
    }

    // Print summary
    std.debug.print("\n=== Summary ===\n", .{});
    const total_runnable = directories.items.len - skipped;
    if (total_runnable > 0) {
        std.debug.print("Total: {d} | Passed: {d} | Failed: {d} | Skipped: {d} | Pass rate: {d:.1}%\n", .{
            directories.items.len,
            passed,
            failed,
            skipped,
            @as(f64, @floatFromInt(passed)) * 100.0 / @as(f64, @floatFromInt(total_runnable)),
        });
    } else {
        std.debug.print("Total: {d} | All tests skipped\n", .{directories.items.len});
    }

    // List tests with no-op blocks
    if (no_op_blocks.items.len > 0) {
        std.debug.print("\nTests with no-op blocks:\n", .{});
        for (no_op_blocks.items) |block| {
            std.debug.print("  - {s}: {s}\n", .{ block.id, block.exceptions });
        }
    }

    // List failed cases
    if (failures.items.len > 0) {
        std.debug.print("\nFailed cases:\n", .{});
        for (failures.items) |failure| {
            std.debug.print("  - {s}: {s}\n", .{ failure.id, @errorName(failure.err) });
        }
    }

    // List skipped tests
    if (skipped_tests.items.len > 0) {
        std.debug.print("\nSkipped tests:\n", .{});
        for (skipped_tests.items) |skipped_test| {
            std.debug.print("  - {s}: {s}\n", .{ skipped_test.id, skipped_test.reason });
        }
    }
}

fn discoverReportDirectories(allocator: std.mem.Allocator, base_path: []const u8) !std.ArrayList([]const u8) {
    var directories = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (directories.items) |dir| {
            allocator.free(dir);
        }
        directories.deinit();
    }

    var base_dir = try std.fs.cwd().openDir(base_path, .{ .iterate = true });
    defer base_dir.close();

    var it = base_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, entry.name });
            try directories.append(full_path);
        }
    }

    return directories;
}
