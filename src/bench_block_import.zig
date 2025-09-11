const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const clap = @import("clap");
const types = @import("types.zig");
const block_import = @import("block_import.zig");
const state = @import("state.zig");
const jamtestvectors = @import("jamtestvectors.zig");
const trace_runner = @import("trace_runner/runner.zig");
const parsers = @import("trace_runner/parsers.zig");
const state_dict = @import("state_dictionary.zig");
const io = @import("io.zig");
const jam_params = @import("jam_params.zig");
const Params = jam_params.Params;

const BenchmarkConfig = struct {
    iterations: u32 = 100,
    thread_count: ?usize = null,
    params_name: []const u8 = "tiny",
    trace_filter: ?[]const u8 = null,
    output_format: OutputFormat = .json,

    const OutputFormat = enum { json, human_readable };

    pub fn deinit(self: *BenchmarkConfig, allocator: std.mem.Allocator) void {
        if (self.trace_filter) |filter| {
            allocator.free(filter);
            self.trace_filter = null;
        }
    }
};

const BenchmarkResult = struct {
    trace_name: []const u8,
    iterations: u32,
    times_ns: []u64,
    min_ns: u64,
    max_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    stddev_ns: u64,
};

const BenchmarkReport = struct {
    timestamp: i64,
    git_commit: []const u8,
    params: []const u8,
    results: []const BenchmarkResult,

    fn writeJson(self: *const BenchmarkReport, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.print("  \"timestamp\": {},\n", .{self.timestamp});
        try writer.print("  \"git_commit\": \"{s}\",\n", .{self.git_commit});
        try writer.print("  \"params\": \"{s}\",\n", .{self.params});
        try writer.writeAll("  \"results\": [\n");

        for (self.results, 0..) |result, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"trace_name\": \"{s}\",\n", .{result.trace_name});
            try writer.print("      \"iterations\": {},\n", .{result.iterations});
            try writer.print("      \"min_ns\": {},\n", .{result.min_ns});
            try writer.print("      \"max_ns\": {},\n", .{result.max_ns});
            try writer.print("      \"median_ns\": {},\n", .{result.median_ns});
            try writer.print("      \"mean_ns\": {},\n", .{result.mean_ns});
            try writer.print("      \"stddev_ns\": {}\n", .{result.stddev_ns});
            try writer.writeAll("    }");
            if (i < self.results.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }

        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");
    }
};

fn calculateStats(times: []u64) struct { min: u64, max: u64, median: u64, mean: u64, stddev: u64 } {
    if (times.len == 0) return .{ .min = 0, .max = 0, .median = 0, .mean = 0, .stddev = 0 };

    std.mem.sort(u64, times, {}, std.sort.asc(u64));

    // After sorting, min/max are trivial O(1) operations:
    const min = times[0];
    const max = times[times.len - 1];

    // Calculate median directly from sorted array
    const median = if (times.len % 2 == 0)
        (times[times.len / 2 - 1] + times[times.len / 2]) / 2
    else
        times[times.len / 2];

    // Calculate sum in single pass
    var sum: u64 = 0;
    for (times) |t| {
        sum += t;
    }
    const mean = sum / times.len;

    // Calculate standard deviation in single pass
    var variance_sum: u64 = 0;
    for (times) |t| {
        const diff = if (t > mean) t - mean else mean - t;
        variance_sum += diff * diff;
    }
    const variance = variance_sum / times.len;
    const stddev_float = std.math.sqrt(@as(f64, @floatFromInt(variance)));

    return .{
        .min = min,
        .max = max,
        .median = median,
        .mean = mean,
        .stddev = @intFromFloat(stddev_float),
    };
}

fn BenchmarkContext(comptime IOExecutor: type) type {
    return struct {
        allocator: std.mem.Allocator,
        config: BenchmarkConfig,
        timestamp: i64,
        executor: *IOExecutor,
        loader: parsers.w3f.Loader(jamtestvectors.W3F_PARAMS),
        params: jam_params.Params,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, config: BenchmarkConfig, executor: *IOExecutor) Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .timestamp = std.time.timestamp(),
                .executor = executor,
                .loader = parsers.w3f.Loader(jamtestvectors.W3F_PARAMS){},
                .params = jamtestvectors.W3F_PARAMS,
            };
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
        }
    };
}

fn loadTraceFiles(arena: std.mem.Allocator, trace_name: []const u8) ![][]const u8 {
    const trace_path = try std.fmt.allocPrint(arena, "src/jamtestvectors/data/traces/{s}", .{trace_name});

    var trace_files = std.ArrayList([]const u8).init(arena);

    var trace_dir = try std.fs.cwd().openDir(trace_path, .{ .iterate = true });
    defer trace_dir.close();

    var walker = try trace_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".bin")) continue;

        const full_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ trace_path, entry.path });
        try trace_files.append(full_path);
    }

    return trace_files.items;
}

fn loadTransitions(context: anytype, arena: std.mem.Allocator, trace_files: []const []const u8) ![]parsers.StateTransition {
    var transitions = std.ArrayList(parsers.StateTransition).init(arena);

    for (trace_files) |file_path| {
        if (std.mem.indexOf(u8, file_path, "genesis.bin") != null) {
            continue;
        }

        const transition = context.loader.loader().loadTestVector(context.allocator, file_path) catch |err| {
            std.debug.print("  Warning: Failed to load {s}: {}\n", .{ file_path, err });
            continue;
        };

        transitions.append(transition) catch |err| {
            transition.deinit(context.allocator);
            return err;
        };
    }

    return transitions.items;
}

fn executeBenchmarkBatch(comptime IOExecutor: type, context: BenchmarkContext(IOExecutor), arena: std.mem.Allocator, transitions: []const parsers.StateTransition, times_buffer: []u64) !usize {
    std.debug.assert(times_buffer.len >= context.config.iterations);
    const times = times_buffer[0..context.config.iterations];

    var jam_state = try state.JamState(jamtestvectors.W3F_PARAMS).init(context.allocator);
    defer jam_state.deinit(context.allocator);

    if (transitions.len > 0) {
        var dict = try transitions[0].preStateAsMerklizationDict(arena);
        defer dict.deinit();

        jam_state = try state_dict.reconstruct.reconstructState(jamtestvectors.W3F_PARAMS, context.allocator, &dict);
    }

    var successful_runs: usize = 0;
    var run_idx: usize = 0;

    var cached_state_root = try jam_state.buildStateRoot(context.allocator);

    while (successful_runs < context.config.iterations) : (run_idx += 1) {
        if (run_idx > context.config.iterations * 10) {
            std.debug.print("  Warning: Too many failures, stopping at {} successful runs\n", .{successful_runs});
            break;
        }

        const transition = &transitions[run_idx % transitions.len];

        if (run_idx > 0 and run_idx % transitions.len == 0) {
            jam_state.deinit(context.allocator);
            jam_state = try state.JamState(jamtestvectors.W3F_PARAMS).init(context.allocator);

            var dict = try transitions[0].preStateAsMerklizationDict(arena);
            defer dict.deinit();

            jam_state = try state_dict.reconstruct.reconstructState(jamtestvectors.W3F_PARAMS, context.allocator, &dict);
            cached_state_root = try jam_state.buildStateRoot(context.allocator);
        }

        var importer = block_import.BlockImporter(
            IOExecutor,
            jamtestvectors.W3F_PARAMS,
        ).init(context.executor, context.allocator);

        const start = std.time.nanoTimestamp();

        var result = try importer.importBlockWithCachedRoot(&jam_state, cached_state_root, transition.block());

        try result.commit();
        result.deinit();

        cached_state_root = try jam_state.buildStateRoot(context.allocator);

        const end = std.time.nanoTimestamp();
        times[successful_runs] = @intCast(end - start);
        successful_runs += 1;
    }

    return successful_runs;
}

fn generateBenchmarkReport(context: anytype, arena: std.mem.Allocator, results: []const BenchmarkResult, git_commit: []const u8) !void {
    std.fs.cwd().makeDir("bench") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const report = BenchmarkReport{
        .timestamp = context.timestamp,
        .git_commit = git_commit,
        .params = context.config.params_name,
        .results = results,
    };

    const filename = try std.fmt.allocPrint(arena, "bench/{d}.json", .{context.timestamp});

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    var buffered = std.io.bufferedWriter(file.writer());
    try report.writeJson(buffered.writer());
    try buffered.flush();

    std.debug.print("\nBenchmark results written to: {s}\n", .{filename});
}

fn getCurrentGitCommit(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .max_output_bytes = 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "unknown-no-git"),
        error.AccessDenied => return allocator.dupe(u8, "unknown-no-access"),
        else => return err,
    };

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .Exited or result.term.Exited != 0) {
        return allocator.dupe(u8, "unknown-git-error");
    }

    const commit_full = std.mem.trim(u8, result.stdout, " \n\r\t");
    const commit_short = commit_full[0..@min(commit_full.len, 8)];
    return allocator.dupe(u8, commit_short);
}

pub fn benchmarkBlockImportWithBufferAndConfig(
    comptime IOExecutor: type,
    executor: *IOExecutor,
    allocator: std.mem.Allocator,
    times_buffer: []u64,
    config: BenchmarkConfig,
) !void {
    var context = BenchmarkContext(IOExecutor).init(allocator, config, executor);
    defer context.deinit();

    // Create arena for temporary allocations during benchmarking
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const git_commit = getCurrentGitCommit(allocator) catch "unknown-git-failed";
    defer allocator.free(git_commit);

    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer {
        for (results.items) |result| {
            allocator.free(result.trace_name);
        }
        results.deinit();
    }

    const trace_dirs = [_][]const u8{
        "fallback",
        "safrole",
        "preimages",
        "preimages_light",
        "storage",
        "storage_light",
    };

    // Validate trace filter if provided
    if (context.config.trace_filter) |filter| {
        var valid_filter = false;
        for (trace_dirs) |trace_name| {
            if (std.mem.eql(u8, trace_name, filter)) {
                valid_filter = true;
                break;
            }
        }
        if (!valid_filter) {
            std.debug.print("Error: Unknown trace '{s}'. Available traces: ", .{filter});
            for (trace_dirs, 0..) |trace_name, i| {
                std.debug.print("{s}", .{trace_name});
                if (i < trace_dirs.len - 1) std.debug.print("{s}", .{", "});
            }
            std.debug.print("{s}", .{"\n"});
            return;
        }
    }

    for (trace_dirs) |trace_name| {
        // Skip traces that don't match the filter
        if (context.config.trace_filter) |filter| {
            if (!std.mem.eql(u8, trace_name, filter)) {
                continue;
            }
        }
        // Clear arena between trace directories
        _ = arena_allocator.reset(.retain_capacity);

        std.debug.print("Benchmarking trace: {s}\n", .{trace_name});

        const trace_files = loadTraceFiles(arena, trace_name) catch |err| {
            std.debug.print("  Failed to load trace files: {}\n", .{err});
            continue;
        };

        if (trace_files.len == 0) {
            std.debug.print("  No traces found, skipping\n", .{});
            continue;
        }

        const transitions = loadTransitions(&context, arena, trace_files) catch |err| {
            std.debug.print("  Failed to load transitions: {}\n", .{err});
            continue;
        };
        defer {
            for (transitions) |*transition| {
                transition.deinit(allocator);
            }
        }

        if (transitions.len == 0) {
            std.debug.print("  No valid transitions loaded, skipping\n", .{});
            continue;
        }

        const successful_runs = executeBenchmarkBatch(IOExecutor, context, arena, transitions, times_buffer) catch |err| {
            std.debug.print("  Benchmark execution failed: {}\n", .{err});
            continue;
        };

        if (successful_runs == 0) {
            std.debug.print("  No successful runs, skipping\n", .{});
            continue;
        }

        const adjusted_times = times_buffer[0..successful_runs];
        const stats = calculateStats(adjusted_times);

        try results.append(BenchmarkResult{
            .trace_name = try allocator.dupe(u8, trace_name),
            .iterations = @intCast(successful_runs),
            .times_ns = adjusted_times,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .median_ns = stats.median,
            .mean_ns = stats.mean,
            .stddev_ns = stats.stddev,
        });

        std.debug.print("  Min: {} ns, Max: {} ns, Median: {} ns\n", .{ stats.min, stats.max, stats.median });
    }

    try generateBenchmarkReport(&context, arena, results.items, git_commit);
}

pub fn benchmarkBlockImportWithBuffer(comptime IOExecutor: type, allocator: std.mem.Allocator, times_buffer: []u64, iterations: u32, executor: *IOExecutor) !void {
    const config = BenchmarkConfig{ .iterations = iterations };
    return benchmarkBlockImportWithBufferAndConfig(IOExecutor, executor, allocator, times_buffer, config);
}

pub fn benchmarkBlockImportWithConfig(comptime IOExecutor: type, allocator: std.mem.Allocator, config: BenchmarkConfig, executor: *IOExecutor) !void {
    const times_buffer = try allocator.alloc(u64, config.iterations);
    defer allocator.free(times_buffer);
    return benchmarkBlockImportWithBufferAndConfig(IOExecutor, executor, allocator, times_buffer, config);
}

pub fn benchmarkBlockImport(comptime IOExecutor: type, allocator: std.mem.Allocator, iterations: u32, executor: *IOExecutor) !void {
    const config = BenchmarkConfig{ .iterations = iterations };
    return benchmarkBlockImportWithConfig(IOExecutor, allocator, config, executor);
}

fn showHelp(params: anytype) !void {
    std.debug.print(
        \\JamZig⚡ Block Import Benchmark
        \\
        \\Benchmarks block import performance across different JAM trace types.
        \\
    , .{});
    try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    std.debug.print(
        \\
        \\Usage: bench_block_import [iterations] [trace]
        \\  iterations   Number of iterations per trace (default: 100)
        \\  trace        Run only specific trace (optional)
        \\
        \\Available traces: fallback, safrole, preimages, preimages_light, storage, storage_light
        \\
        \\Examples:
        \\  bench_block_import              # 100 iterations, all traces
        \\  bench_block_import 50           # 50 iterations, all traces
        \\  bench_block_import 25 safrole   # 25 iterations, safrole only
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator) !BenchmarkConfig {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\<u32>
        \\<str>
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        try showHelp(params);
        std.process.exit(1);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try showHelp(params);
        std.process.exit(0);
    }

    var config = BenchmarkConfig{};

    // Handle positional arguments
    if (res.positionals.len > 0) {
        // First positional: iterations (already parsed as u32 by clap)
        if (res.positionals[0]) |iterations| {
            config.iterations = iterations;
        }
    }

    if (res.positionals.len > 1) {
        // Second positional: trace name (already parsed as string by clap)
        if (res.positionals[1]) |trace_name| {
            const valid_traces = [_][]const u8{ "fallback", "safrole", "preimages", "preimages_light", "storage", "storage_light" };

            var valid = false;
            for (valid_traces) |valid_trace| {
                if (std.mem.eql(u8, trace_name, valid_trace)) {
                    valid = true;
                    break;
                }
            }

            if (!valid) {
                std.debug.print("Error: Invalid trace '{s}'. Valid traces: ", .{trace_name});
                for (valid_traces, 0..) |valid_trace, idx| {
                    std.debug.print("{s}", .{valid_trace});
                    if (idx < valid_traces.len - 1) std.debug.print(", ", .{});
                }
                std.debug.print("\n", .{});
                return error.InvalidArguments;
            }

            config.trace_filter = try allocator.dupe(u8, trace_name);
        }
    }

    if (res.positionals.len > 2) {
        std.debug.print("Error: Too many positional arguments. Expected at most 2.\n", .{});
        try showHelp(params);
        return error.InvalidArguments;
    }

    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = parseArgs(allocator) catch |err| switch (err) {
        error.InvalidArguments => std.process.exit(1),
        else => return err,
    };
    defer config.deinit(allocator);

    std.debug.print("Using JAM params: {any}\n", .{config});

    // const ExecutorType = io.SequentialExecutor;
    const ExecutorType = io.ThreadPoolExecutor;

    var executor = try ExecutorType.init(allocator);
    defer executor.deinit();

    if (config.trace_filter) |filter| {
        std.debug.print("Running {} iterations for trace: {s}\n", .{ config.iterations, filter });
    } else {
        std.debug.print("Running {} iterations per trace...\n", .{config.iterations});
    }

    try benchmarkBlockImportWithConfig(ExecutorType, allocator, config, &executor);
}
