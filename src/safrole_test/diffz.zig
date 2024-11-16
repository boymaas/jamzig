const std = @import("std");
const safrole = @import("../safrole.zig");
const safrole_types = @import("../safrole/types.zig");

const tmpfile = @import("tmpfile");

pub const Error = error{OutOfMemory};

pub fn diffStates(
    allocator: std.mem.Allocator,
    before: *const safrole_types.State,
    after: *const safrole_types.State,
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

    // Return the owned slice, to be freed by calleer
    return result.stdout;
}
