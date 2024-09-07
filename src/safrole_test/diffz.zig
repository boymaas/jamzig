const std = @import("std");
const safrole = @import("../safrole.zig");

const tmpfile = @import("tmpfile");

pub const Error = error{OutOfMemory};

pub fn diffStates(
    allocator: std.mem.Allocator,
    before: *const safrole.types.State,
    after: *const safrole.types.State,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    // Print both before and after states
    const before_str = try std.fmt.allocPrint(arena_alloc, "{any}", .{before});
    const after_str = try std.fmt.allocPrint(arena_alloc, "{any}", .{after});

    // Create temporary files to store the before and after states
    var before_file = try tmpfile.tmpFile(.{});
    defer before_file.deinit();
    var after_file = try tmpfile.tmpFile(.{});
    defer after_file.deinit();

    // Write to the tempfiles
    try before_file.f.writeAll(before_str);
    try after_file.f.writeAll(after_str);

    // Now do a context diff between the two files
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{ "diff", "-u", before_file.abs_path, after_file.abs_path } });
    defer allocator.free(result.stderr);

    // Return the owned slice, to be freed by calleer
    return result.stdout;
}
