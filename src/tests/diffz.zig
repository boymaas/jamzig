const std = @import("std");
const Allocator = std.mem.Allocator;
const diffz = @import("diffz");

pub fn debugPrintDiffMarkChanges(allocator: Allocator, before: []const u8, after: []const u8) !void {
    const config = diffz{
        .diff_check_lines_over = 0, // Always use line mode
    };
    var diff = try config.diff(allocator, before, after, true);
    defer diffz.deinitDiffList(allocator, &diff);

    const stderr = std.io.getStdErr().writer();
    const yellow = "\x1b[33m";
    const reset = "\x1b[0m";

    var i: usize = 0;
    while (i < diff.items.len) {
        switch (diff.items[i].operation) {
            .equal => try stderr.print("{s}", .{diff.items[i].text}),
            .delete, .insert => {
                var combined = std.ArrayList(u8).init(allocator);
                defer combined.deinit();

                var j = i;
                while (j < diff.items.len and diff.items[j].operation != .equal) : (j += 1) {
                    if (diff.items[j].operation == .insert) {
                        try combined.appendSlice(diff.items[j].text);
                    }
                }

                if (combined.items.len > 0) {
                    try stderr.print("{s}{s}{s}", .{ yellow, combined.items, reset });
                }

                i = j - 1;
            },
        }
        i += 1;
    }
    try stderr.print("\n", .{});
}
