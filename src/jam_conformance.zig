const std = @import("std");
const testing = std.testing;

const jam_params = @import("jam_params.zig");
const trace_runner = @import("trace_runner/runner.zig");
const parsers = @import("trace_runner/parsers.zig");
const messages = @import("fuzz_protocol/messages.zig");
const version = @import("version.zig");
const io = @import("io.zig");

// Use FUZZ_PARAMS for consistency with fuzz protocol testing
const FUZZ_PARAMS = jam_params.TINY_PARAMS;

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
    // .{
    //     .id = "1756548459",
    //     .reason = "PolkaJam error: accepts service ID 2^32 which exceeds ℕ₃₂ domain [0, 2^32-1] per GP B.37. JamZig correctly returns WHO error.",
    // },
    // .{
    //     .id = "1755530728",
    //     .reason = "PolkaJam error: expects less gas than actually consumed (13048 vs 13063)",
    // },
    // .{
    //     .id = "1755530896",
    //     .reason = "PolkaJam error: expects less gas than actually consumed (12539 vs 12667)",
    // },
};

// -- Data Structures for Flexible Trace Management --

const PathConfig = struct {
    name: []const u8,
    path: []const u8,
};

const TraceDir = struct {
    name: []const u8,
    base_path: []const u8,
    timestamps: std.ArrayList([]const u8),

    fn deinit(self: *TraceDir, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.base_path);
        for (self.timestamps.items) |timestamp| {
            allocator.free(timestamp);
        }
        self.timestamps.deinit();
        self.* = undefined;
    }
};

const TraceEntry = struct {
    source_name: []const u8,
    timestamp: []const u8,
    full_path: []const u8,
};

const TraceCollection = struct {
    allocator: std.mem.Allocator,
    dirs: std.ArrayList(TraceDir),

    pub fn init(allocator: std.mem.Allocator) TraceCollection {
        return .{
            .allocator = allocator,
            .dirs = std.ArrayList(TraceDir).init(allocator),
        };
    }

    pub fn deinit(self: *TraceCollection) void {
        for (self.dirs.items) |*dir| {
            dir.deinit(self.allocator);
        }
        self.dirs.deinit();
        self.* = undefined;
    }

    pub fn discover(self: *TraceCollection, paths: []const PathConfig) !void {
        for (paths) |path_config| {
            var timestamps = std.ArrayList([]const u8).init(self.allocator);
            errdefer {
                for (timestamps.items) |timestamp| {
                    self.allocator.free(timestamp);
                }
                timestamps.deinit();
            }

            // Try to open the directory, if it doesn't exist, skip it
            var base_dir = std.fs.cwd().openDir(path_config.path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer base_dir.close();

            // Scan for timestamp directories
            var it = base_dir.iterate();
            while (try it.next()) |entry| {
                // Only accept directories with valid timestamp format (digits only)
                if (entry.kind == .directory and isValidTimestamp(entry.name)) {
                    const timestamp = try self.allocator.dupe(u8, entry.name);
                    try timestamps.append(timestamp);
                }
            }

            // Only add if we found any traces
            if (timestamps.items.len > 0) {
                try self.dirs.append(.{
                    .name = try self.allocator.dupe(u8, path_config.name),
                    .base_path = try self.allocator.dupe(u8, path_config.path),
                    .timestamps = timestamps,
                });
            }
        }
    }

    pub fn findByTimestamp(self: *const TraceCollection, timestamp: []const u8) !?TraceEntry {
        for (self.dirs.items) |dir| {
            for (dir.timestamps.items) |dir_timestamp| {
                if (std.mem.eql(u8, dir_timestamp, timestamp)) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir.base_path, timestamp });
                    return TraceEntry{
                        .source_name = dir.name,
                        .timestamp = dir_timestamp,
                        .full_path = full_path,
                    };
                }
            }
        }
        return null;
    }

    pub const Iterator = struct {
        collection: *const TraceCollection,
        dir_index: usize,
        timestamp_index: usize,
        allocator: std.mem.Allocator,

        pub fn next(self: *Iterator) !?TraceEntry {
            while (self.dir_index < self.collection.dirs.items.len) {
                const dir = &self.collection.dirs.items[self.dir_index];

                if (self.timestamp_index < dir.timestamps.items.len) {
                    const timestamp = dir.timestamps.items[self.timestamp_index];
                    self.timestamp_index += 1;

                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir.base_path, timestamp });

                    return TraceEntry{
                        .source_name = dir.name,
                        .timestamp = timestamp,
                        .full_path = full_path,
                    };
                }

                self.dir_index += 1;
                self.timestamp_index = 0;
            }

            return null;
        }
    };

    pub fn iterator(self: *const TraceCollection) Iterator {
        return .{
            .collection = self,
            .dir_index = 0,
            .timestamp_index = 0,
            .allocator = self.allocator,
        };
    }
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

    // Build collection from all configured paths
    var collection = try buildStandardTraceCollection(allocator);
    defer collection.deinit();

    // Find the specific timestamp
    const maybe_entry = try collection.findByTimestamp(trace_timestamp);
    if (maybe_entry) |entry| {
        defer allocator.free(entry.full_path);

        std.debug.print("Running trace test for: {s} (from {s})\n", .{ trace_timestamp, entry.source_name });

        // Run test for the specific directory using new simplified runner
        const w3f_loader = parsers.w3f.Loader(FUZZ_PARAMS){};
        const loader = w3f_loader.loader();

        var sequential_executor = try io.SequentialExecutor.init(allocator);
        defer sequential_executor.deinit();

        // Create embedded fuzzer
        var fuzzer = try trace_runner.fuzzer_mod.createEmbeddedFuzzer(FUZZ_PARAMS, &sequential_executor, allocator, 0);
        defer fuzzer.destroy();

        // Connect and handshake with embedded target
        try fuzzer.connectToTarget();
        try fuzzer.performHandshake();

        // Create trace iterator
        var trace_iter = try trace_runner.traceIterator(allocator, loader, entry.full_path);
        defer trace_iter.deinit();

        // Process all traces
        var results = std.ArrayList(trace_runner.TraceResult).init(allocator);
        defer {
            for (results.items) |*result| {
                result.deinit(allocator);
            }
            results.deinit();
        }

        var trace_names = std.ArrayList([]u8).init(allocator);
        defer {
            for (trace_names.items) |name| {
                allocator.free(name);
            }
            trace_names.deinit();
        }

        var is_first = true;
        var trace_index: usize = 0;
        while (try trace_iter.next()) |transition| {
            defer transition.deinit(allocator);

            // Extract trace name from transition index for reporting
            const trace_name = try std.fmt.allocPrint(allocator, "trace_{d}", .{trace_index});
            try trace_names.append(trace_name);

            const result = try trace_runner.processTrace(FUZZ_PARAMS, fuzzer, transition, is_first);
            try results.append(result);

            // Stop on first error for individual trace test
            switch (result) {
                .@"error" => |err_info| {
                    std.debug.print("Error processing trace {d}: {s} - {s}\n", .{ trace_index, @errorName(err_info.err), err_info.context });
                    return err_info.err;
                },
                .mismatch => |mismatch| {
                    std.debug.print("State mismatch in trace {d}:\n", .{trace_index});
                    std.debug.print("  Expected: {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.expected_root)});
                    std.debug.print("  Actual:   {s}\n", .{std.fmt.fmtSliceHexLower(&mismatch.actual_root)});
                    return error.StateMismatch;
                },
                .no_op => |no_op| {
                    std.debug.print("Trace {d} resulted in no-op: {s}\n", .{ trace_index, no_op.error_name });
                },
                else => {},
            }

            is_first = false;
            trace_index += 1;
        }

        std.debug.print("Successfully processed {d} traces\n", .{results.items.len});
    } else {
        std.debug.print("Error: Trace {s} not found in any configured path\n", .{trace_timestamp});
        return error.TraceNotFound;
    }
}

test "jam-conformance:summary" {
    const allocator = testing.allocator;

    // Build collection from all configured paths
    var collection = try buildStandardTraceCollection(allocator);
    defer collection.deinit();

    try runTraceSummary(allocator, &collection);
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

/// Check if a directory name is a valid timestamp
/// Accepts two formats:
///   1. Plain timestamp: all digits (e.g., "1766241814")
///   2. Fuzzing variant: timestamp_number (e.g., "1766243315_1733")
fn isValidTimestamp(name: []const u8) bool {
    if (name.len == 0) return false;

    // Check for underscore to determine format
    if (std.mem.indexOfScalar(u8, name, '_')) |underscore_pos| {
        // New format: <timestamp>_<number>
        // Must have digits before and after underscore
        if (underscore_pos == 0 or underscore_pos == name.len - 1) {
            return false;
        }

        // Validate prefix (before underscore) contains only digits
        for (name[0..underscore_pos]) |char| {
            if (!std.ascii.isDigit(char)) {
                return false;
            }
        }

        // Validate suffix (after underscore) contains only digits
        for (name[underscore_pos + 1 ..]) |char| {
            if (!std.ascii.isDigit(char)) {
                return false;
            }
        }

        return true;
    } else {
        // Old format: plain timestamp (all digits)
        for (name) |char| {
            if (!std.ascii.isDigit(char)) {
                return false;
            }
        }

        return true;
    }
}

/// Build a standard TraceCollection with configured paths
fn buildStandardTraceCollection(allocator: std.mem.Allocator) !TraceCollection {
    var collection = TraceCollection.init(allocator);
    errdefer collection.deinit();

    const traces_path = try buildTracesPath(allocator);
    defer allocator.free(traces_path);

    const testing_path = try std.fmt.allocPrint(allocator, "{s}/TESTING", .{traces_path});
    defer allocator.free(testing_path);

    const paths = [_]PathConfig{
        .{ .name = "traces", .path = traces_path },
        .{ .name = "testing", .path = testing_path },
    };
    try collection.discover(&paths);

    return collection;
}

fn buildTracesPath(allocator: std.mem.Allocator) ![]u8 {
    const graypaper = version.GRAYPAPER_VERSION;
    const version_str = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ graypaper.major, graypaper.minor, graypaper.patch });
    defer allocator.free(version_str);

    return try std.fmt.allocPrint(allocator, "src/jam-conformance/fuzz-reports/{s}/traces", .{version_str});
}

fn runTraceSummary(allocator: std.mem.Allocator, collection: *const TraceCollection) !void {
    // Count total traces
    var total_count: usize = 0;
    for (collection.dirs.items) |dir| {
        total_count += dir.timestamps.items.len;
    }

    std.debug.print("\n=== Conformance Summary ===\n", .{});
    for (collection.dirs.items) |dir| {
        if (dir.timestamps.items.len > 0) {
            std.debug.print("  {s}: {d} traces\n", .{ dir.name, dir.timestamps.items.len });
        }
    }
    std.debug.print("Total: {d} traces\n\n", .{total_count});

    if (total_count == 0) {
        std.debug.print("No traces found in any configured path\n", .{});
        return;
    }

    // Create W3F loader and executor
    const w3f_loader = parsers.w3f.Loader(FUZZ_PARAMS){};
    const loader = w3f_loader.loader();

    var sequential_executor = try io.SequentialExecutor.init(allocator);
    defer sequential_executor.deinit();

    // Track results by source
    var source_stats = std.StringHashMap(struct {
        passed: usize,
        no_ops: usize,
        failed: usize,
        skipped: usize,
    }).init(allocator);
    defer source_stats.deinit();

    var total_passed: usize = 0;
    var total_no_ops: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;

    // Run traces using the iterator
    var iter = collection.iterator();
    var idx: usize = 1;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.full_path);

        // Get or create stats for this source
        var stats_entry = try source_stats.getOrPut(entry.source_name);
        if (!stats_entry.found_existing) {
            stats_entry.value_ptr.* = .{ .passed = 0, .no_ops = 0, .failed = 0, .skipped = 0 };
        }

        // Check if this test is skipped
        if (isSkippedTest(entry.timestamp)) |reason| {
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ⏭️  SKIPPED ({s})\n", .{ idx, total_count, entry.source_name, entry.timestamp, reason });
            stats_entry.value_ptr.skipped += 1;
            total_skipped += 1;
            idx += 1;
            continue;
        }

        // Create embedded fuzzer for this trace directory
        var fuzzer = trace_runner.fuzzer_mod.createEmbeddedFuzzer(FUZZ_PARAMS, &sequential_executor, allocator, 0) catch |err| {
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ Failed to create fuzzer: {s}\n", .{ idx, total_count, entry.source_name, entry.timestamp, @errorName(err) });
            stats_entry.value_ptr.failed += 1;
            total_failed += 1;
            idx += 1;
            continue;
        };
        defer fuzzer.destroy();

        // Connect and handshake
        fuzzer.connectToTarget() catch |err| {
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ Connect failed: {s}\n", .{ idx, total_count, entry.source_name, entry.timestamp, @errorName(err) });
            stats_entry.value_ptr.failed += 1;
            total_failed += 1;
            idx += 1;
            continue;
        };

        fuzzer.performHandshake() catch |err| {
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ Handshake failed: {s}\n", .{ idx, total_count, entry.source_name, entry.timestamp, @errorName(err) });
            stats_entry.value_ptr.failed += 1;
            total_failed += 1;
            idx += 1;
            continue;
        };

        // Create trace iterator for this directory
        var trace_iter = trace_runner.traceIterator(allocator, loader, entry.full_path) catch |err| {
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ Iterator failed: {s}\n", .{ idx, total_count, entry.source_name, entry.timestamp, @errorName(err) });
            stats_entry.value_ptr.failed += 1;
            total_failed += 1;
            idx += 1;
            continue;
        };
        defer trace_iter.deinit();

        // Process all traces in this directory
        var trace_results = std.ArrayList(trace_runner.TraceResult).init(allocator);
        defer {
            for (trace_results.items) |*result| {
                result.deinit(allocator);
            }
            trace_results.deinit();
        }

        var trace_names = std.ArrayList([]u8).init(allocator);
        defer {
            for (trace_names.items) |name| {
                allocator.free(name);
            }
            trace_names.deinit();
        }

        var is_first = true;
        var trace_idx: usize = 0;
        var had_error = false;
        var had_no_op = false;
        var error_details: ?[]const u8 = null;
        while (try trace_iter.next()) |transition| {
            defer transition.deinit(allocator);

            const trace_name = try std.fmt.allocPrint(allocator, "trace_{d}", .{trace_idx});
            try trace_names.append(trace_name);

            const result = trace_runner.processTrace(FUZZ_PARAMS, fuzzer, transition, is_first) catch |err| {
                std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ Process failed: {s}\n", .{ idx, total_count, entry.source_name, entry.timestamp, @errorName(err) });
                had_error = true;
                break;
            };

            switch (result) {
                .@"error" => |err_info| {
                    had_error = true;
                    error_details = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ @errorName(err_info.err), err_info.context });
                },
                .mismatch => {
                    had_error = true;
                    error_details = try allocator.dupe(u8, "State root mismatch");
                },
                .no_op => {
                    had_no_op = true;
                },
                else => {},
            }

            try trace_results.append(result);
            is_first = false;
            trace_idx += 1;
        }

        if (had_error) {
            stats_entry.value_ptr.failed += 1;
            total_failed += 1;

            if (error_details) |details| {
                defer allocator.free(details);
                std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ {s}\n", .{ idx, total_count, entry.source_name, entry.timestamp, details });
            } else {
                std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ❌ FAILED\n", .{ idx, total_count, entry.source_name, entry.timestamp });
            }
        } else if (had_no_op) {
            stats_entry.value_ptr.no_ops += 1;
            total_no_ops += 1;
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ✅ PASS 🟡 NO-OP\n", .{ idx, total_count, entry.source_name, entry.timestamp });
        } else {
            stats_entry.value_ptr.passed += 1;
            total_passed += 1;
            std.debug.print("[{d:3}/{d:3}] [{s:7}] {s}: ✅ PASS\n", .{ idx, total_count, entry.source_name, entry.timestamp });
        }

        idx += 1;
    }

    // Print summary by source
    std.debug.print("\n=== Summary by Source ===\n", .{});
    var stats_iter = source_stats.iterator();
    while (stats_iter.next()) |entry| {
        const stats = entry.value_ptr.*;
        const runnable = stats.passed + stats.no_ops + stats.failed;
        if (runnable > 0) {
            std.debug.print("{s}: Passed: {d} | No-ops: {d} | Failed: {d} | Skipped: {d} | Pass rate: {d:.1}%\n", .{
                entry.key_ptr.*,
                stats.passed,
                stats.no_ops,
                stats.failed,
                stats.skipped,
                @as(f64, @floatFromInt(stats.passed + stats.no_ops)) * 100.0 / @as(f64, @floatFromInt(runnable)),
            });
        } else {
            std.debug.print("{s}: All {d} tests skipped\n", .{ entry.key_ptr.*, stats.skipped });
        }
    }

    // Print overall summary
    std.debug.print("\n=== Overall Summary ===\n", .{});
    const total_runnable = total_passed + total_no_ops + total_failed;
    if (total_runnable > 0) {
        std.debug.print("Total: {d} | Passed: {d} | No-ops: {d} | Failed: {d} | Skipped: {d} | Pass rate: {d:.1}%\n", .{
            total_count,
            total_passed,
            total_no_ops,
            total_failed,
            total_skipped,
            @as(f64, @floatFromInt(total_passed + total_no_ops)) * 100.0 / @as(f64, @floatFromInt(total_runnable)),
        });
    } else {
        std.debug.print("Total: {d} | All tests skipped\n", .{total_count});
    }
}
