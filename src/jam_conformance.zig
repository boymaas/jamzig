const std = @import("std");
const testing = std.testing;

const jam_params = @import("jam_params.zig");
const trace_runner = @import("trace_runner/runner.zig");
const parsers = @import("trace_runner/parsers.zig");
const messages = @import("fuzz_protocol/messages.zig");
const version = @import("version.zig");

// Use FUZZ_PARAMS for consistency with fuzz protocol testing
const FUZZ_PARAMS = messages.FUZZ_PARAMS;

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

fn runReportsInDirectory(allocator: std.mem.Allocator, base_path: []const u8, name: []const u8) !void {
    const directories = try discoverReportDirectories(allocator, base_path);
    defer {
        for (directories.items) |dir| {
            allocator.free(dir);
        }
        directories.deinit();
    }

    std.log.info("Running {s} conformance tests from: {s}", .{ name, base_path });
    std.log.info("Found {d} report directories", .{directories.items.len});

    if (directories.items.len == 0) {
        std.log.warn("No report directories found in {s}", .{base_path});
        return;
    }

    // Create W3F loader for the traces
    const w3f_loader = parsers.w3f.Loader(FUZZ_PARAMS){};
    const loader = w3f_loader.loader();

    // Run traces in each directory
    for (directories.items, 1..) |dir, idx| {
        std.log.info("[{d}/{d}] Running traces in: {s}", .{ idx, directories.items.len, dir });

        // Use TRACE_MODE to validate each transition independently
        try trace_runner.runTracesInDir(
            FUZZ_PARAMS,
            loader,
            allocator,
            dir,
            .CONTINOUS_MODE,
        );
    }
}

test "jam-conformance:jamzig" {
    const allocator = testing.allocator;
    const jamzig_path = "src/jam-conformance/fuzz-reports/jamzig";

    try runReportsInDirectory(allocator, jamzig_path, "JamZig");
}

test "jam-conformance:archive" {
    const allocator = testing.allocator;

    // Use the graypaper version to navigate to the correct archive directory
    const graypaper = version.GRAYPAPER_VERSION;
    const version_str = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ graypaper.major, graypaper.minor, graypaper.patch });
    defer allocator.free(version_str);

    const archive_version_path = try std.fmt.allocPrint(allocator, "src/jam-conformance/fuzz-reports/archive/{s}", .{version_str});
    defer allocator.free(archive_version_path);

    // Run reports in the version-specific archive directory
    try runReportsInDirectory(allocator, archive_version_path, "Archive");
}
