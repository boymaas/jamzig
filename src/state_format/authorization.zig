const std = @import("std");
const Alpha = @import("../authorization.zig").Alpha;

pub fn format(
    self: Alpha,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Alpha{\n");
    
    // Print non-empty pools
    try writer.writeAll("  Pools:\n");
    for (self.pools, 0..) |pool, i| {
        if (pool.len > 0) {
            try writer.print("    Core {d}: ", .{i});
            for (pool.constSlice()) |auth| {
                try writer.print("{s} ", .{std.fmt.fmtSliceHexLower(&auth)});
            }
            try writer.writeAll("\n");
        }
    }

    // Print non-empty queues
    try writer.writeAll("  Queues:\n");
    for (self.queues, 0..) |queue, i| {
        if (queue.len > 0) {
            try writer.print("    Core {d}: ", .{i});
            for (queue.constSlice()) |auth| {
                try writer.print("{s} ", .{std.fmt.fmtSliceHexLower(&auth)});
            }
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("}");
}
