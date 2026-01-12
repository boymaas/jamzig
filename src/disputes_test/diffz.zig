const std = @import("std");
const disputes = @import("../jamtestvectors/disputes.zig");

const tmpfile = @import("tmpfile");

pub const Error = error{OutOfMemory};

pub fn diffStates(
    allocator: std.mem.Allocator,
    before: *const disputes.State,
    after: *const disputes.State,
) ![]u8 {
    const before_str = try std.fmt.allocPrint(allocator, "{any}", .{before});
    defer allocator.free(before_str);
    const after_str = try std.fmt.allocPrint(allocator, "{any}", .{after});
    defer allocator.free(after_str);

    var before_file = try tmpfile.tmpFile(.{});
    defer before_file.deinit();
    var after_file = try tmpfile.tmpFile(.{});
    defer after_file.deinit();

    try before_file.f.writeAll(before_str);
    try after_file.f.writeAll(after_str);
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

    if (result.stdout.len == 0) {
        const empty_diff = try allocator.dupe(u8, "EMPTY_DIFF");
        return empty_diff;
    }
    return result.stdout;
}
