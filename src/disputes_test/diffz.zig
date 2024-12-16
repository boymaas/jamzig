const std = @import("std");
const disputes = @import("../jamtestvectors/disputes.zig");

const tmpfile = @import("tmpfile");

pub const Error = error{OutOfMemory};

// TODO: use the testing/diff.zig
pub fn diffStates(
    allocator: std.mem.Allocator,
    before: *const disputes.State,
    after: *const disputes.State,
) ![]u8 {

    // Print both before and after states
    const before_str = try std.fmt.allocPrint(allocator, "{any}", .{before});
    defer allocator.free(before_str);
    const after_str = try std.fmt.allocPrint(allocator, "{any}", .{after});
    defer allocator.free(after_str);

    // Create temporary files to store the before and after states
    var before_file = try tmpfile.tmpFile(.{});
    defer before_file.deinit();
    var after_file = try tmpfile.tmpFile(.{});
    defer after_file.deinit();

    // Write to the tempfiles
    try before_file.f.writeAll(before_str);
    try after_file.f.writeAll(after_str);

    // Now do a context diff between the two files
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "diff",
            "-u",
            before_file.abs_path,
            after_file.abs_path,
        },
    });
    defer allocator.free(result.stderr);

    // Check if the diff is empty
    if (result.stdout.len == 0) {
        // allocator.free(result.stdout); // Not needed as its empty
        const empty_diff = try allocator.dupe(u8, "EMPTY_DIFF");
        return empty_diff;
    }
    // Return the owned slice, to be freed by caller
    return result.stdout;
}
