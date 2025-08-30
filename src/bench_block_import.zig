const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const block_import = @import("block_import.zig");
const state = @import("state.zig");
const jamtestvectors = @import("jamtestvectors.zig");
const trace_runner = @import("trace_runner/runner.zig");
const parsers = @import("trace_runner/parsers.zig");
const state_dict = @import("state_dictionary.zig");
const Params = @import("jam_params.zig").Params;

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
    results: []BenchmarkResult,

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
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    
    var min: u64 = times[0];
    var max: u64 = times[0];
    var sum: u64 = 0;
    
    for (times) |t| {
        if (t < min) min = t;
        if (t > max) max = t;
        sum += t;
    }
    
    const mean = sum / times.len;
    const median = if (times.len % 2 == 0)
        (times[times.len / 2 - 1] + times[times.len / 2]) / 2
    else
        times[times.len / 2];
    
    // Calculate standard deviation
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

pub fn benchmarkBlockImport(allocator: std.mem.Allocator, iterations: u32) !void {
    const params = jamtestvectors.W3F_PARAMS;
    
    // Get current timestamp
    const timestamp = std.time.timestamp();
    
    // Get git commit (simplified - you may want to run actual git command)
    const git_commit = "unknown";
    
    // Create bench directory if it doesn't exist
    std.fs.cwd().makeDir("bench") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Prepare results array
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    // List of trace directories to benchmark
    const trace_dirs = [_][]const u8{
        "fallback",
        "safrole",
        "preimages",
        "preimages_light",
        "storage",
        "storage_light",
    };
    
    const loader = parsers.w3f.Loader(params){};
    
    for (trace_dirs) |trace_name| {
        std.debug.print("Benchmarking trace: {s}\n", .{trace_name});
        
        const trace_path = try std.fmt.allocPrint(allocator, "src/jamtestvectors/data/traces/{s}", .{trace_name});
        defer allocator.free(trace_path);
        
        // Get list of trace files
        var trace_files = std.ArrayList([]const u8).init(allocator);
        defer {
            for (trace_files.items) |file| {
                allocator.free(file);
            }
            trace_files.deinit();
        }
        
        var trace_dir = try std.fs.cwd().openDir(trace_path, .{ .iterate = true });
        defer trace_dir.close();
        
        var walker = try trace_dir.walk(allocator);
        defer walker.deinit();
        
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".bin")) continue;
            
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trace_path, entry.path });
            try trace_files.append(full_path);
        }
        
        if (trace_files.items.len == 0) {
            std.debug.print("  No traces found, skipping\n", .{});
            continue;
        }
        
        // Pre-load all traces
        var transitions = std.ArrayList(parsers.StateTransition).init(allocator);
        defer {
            for (transitions.items) |*transition| {
                transition.deinit(allocator);
            }
            transitions.deinit();
        }
        
        for (trace_files.items) |file_path| {
            // Skip genesis.bin if it exists
            if (std.mem.indexOf(u8, file_path, "genesis.bin") != null) {
                continue;
            }
            
            const transition = loader.loader().loadTestVector(allocator, file_path) catch |err| {
                std.debug.print("  Warning: Failed to load {s}: {}\n", .{ file_path, err });
                continue;
            };
            try transitions.append(transition);
        }
        
        // Skip if no valid transitions loaded
        if (transitions.items.len == 0) {
            std.debug.print("  No valid transitions loaded, skipping\n", .{});
            continue;
        }
        
        // Run benchmarks for this trace set
        var times = try allocator.alloc(u64, iterations);
        defer allocator.free(times);
        
        // Create a persistent state that we'll update through all blocks
        var jam_state = try state.JamState(params).init(allocator);
        defer jam_state.deinit(allocator);
        
        // Initialize from first trace's pre-state
        if (transitions.items.len > 0) {
            var dict = try transitions.items[0].preStateAsMerklizationDict(allocator);
            defer dict.deinit();
            
            jam_state = try state_dict.reconstruct.reconstructState(params, allocator, &dict);
        }
        
        var successful_runs: usize = 0;
        var run_idx: usize = 0;
        
        while (successful_runs < iterations) : (run_idx += 1) {
            // If we've tried too many times, break
            if (run_idx > iterations * 10) {
                std.debug.print("  Warning: Too many failures, stopping at {} successful runs\n", .{successful_runs});
                break;
            }
            
            // Pick a trace (rotate through them sequentially)
            const transition = &transitions.items[run_idx % transitions.items.len];
            
            // If we're starting a new round through the traces, reset state
            if (run_idx > 0 and run_idx % transitions.items.len == 0) {
                jam_state.deinit(allocator);
                jam_state = try state.JamState(params).init(allocator);
                
                var dict = try transitions.items[0].preStateAsMerklizationDict(allocator);
                defer dict.deinit();
                
                jam_state = try state_dict.reconstruct.reconstructState(params, allocator, &dict);
            }
            
            // Create block importer
            var importer = block_import.BlockImporter(params).init(allocator);
            
            // Measure block import time (excluding state root verification)
            const start = std.time.nanoTimestamp();
            
            // Import the block (this is what we're measuring)
            var result = importer.importBlock(&jam_state, transition.block()) catch {
                // On error, reset to this transition's pre-state and try again
                jam_state.deinit(allocator);
                jam_state = try state.JamState(params).init(allocator);
                
                var dict = try transition.preStateAsMerklizationDict(allocator);
                defer dict.deinit();
                
                jam_state = try state_dict.reconstruct.reconstructState(params, allocator, &dict);
                continue;
            };
            
            // Apply the state transition
            try result.commit();
            result.deinit();
            
            const end = std.time.nanoTimestamp();
            times[successful_runs] = @intCast(end - start);
            successful_runs += 1;
        }
        
        // Skip if no successful runs
        if (successful_runs == 0) {
            std.debug.print("  No successful runs, skipping\n", .{});
            continue;
        }
        
        // Adjust times array if we got fewer successful runs
        if (successful_runs < iterations) {
            times = times[0..successful_runs];
        }
        
        // Calculate statistics
        const stats = calculateStats(times);
        
        try results.append(BenchmarkResult{
            .trace_name = trace_name,
            .iterations = iterations,
            .times_ns = times,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .median_ns = stats.median,
            .mean_ns = stats.mean,
            .stddev_ns = stats.stddev,
        });
        
        std.debug.print("  Min: {} ns, Max: {} ns, Median: {} ns\n", .{ stats.min, stats.max, stats.median });
    }
    
    // Create report
    const report = BenchmarkReport{
        .timestamp = timestamp,
        .git_commit = git_commit,
        .params = "tiny",
        .results = results.items,
    };
    
    // Write to file with current date
    const date_str = blk: {
        // Simple date format YYYYMMDD
        const now = std.time.timestamp();
        const day_seconds: i64 = 86400;
        const epoch_days = @divFloor(now, day_seconds);
        
        // Rough calculation (good enough for file naming)
        const years_since_1970 = @divFloor(epoch_days, 365);
        const year: u32 = @intCast(1970 + years_since_1970);
        
        // For simplicity, just use year-01-01 format
        // You could enhance this with proper date calculation if needed
        break :blk try std.fmt.allocPrint(allocator, "{d:0>4}0101", .{year});
    };
    defer allocator.free(date_str);
    
    const filename = try std.fmt.allocPrint(allocator, "bench/{s}.json", .{date_str});
    defer allocator.free(filename);
    
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    
    var buffered = std.io.bufferedWriter(file.writer());
    try report.writeJson(buffered.writer());
    try buffered.flush();
    
    std.debug.print("\nBenchmark results written to: {s}\n", .{filename});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try benchmarkBlockImport(allocator, 100);
}