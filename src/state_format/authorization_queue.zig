const std = @import("std");
const Phi = @import("../authorization_queue.zig").Phi;

pub fn format(
    self: *const Phi,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Phi{\n");
    for (self.queue, 0..) |core_queue, i| {
        if (core_queue.items.len > 0) {
            try writer.print("  Core {d}: ", .{i});
            for (core_queue.items) |hash| {
                try writer.print("{s} ", .{std.fmt.fmtSliceHexLower(&hash)});
            }
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("}");
}
