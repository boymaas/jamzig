const std = @import("std");
const Phi = @import("../authorization_queue.zig").Phi;

pub fn format(
    self: anytype,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Phi{\n");
    var printed_any = false;
    for (self.queue, 0..) |core_entry, core_idx| {
        if (core_entry.items.len > 0) {
            printed_any = true;
            try writer.print("  [{d}]Authorization Queue:\n", .{core_idx});

            for (core_entry.items, 0..) |entry, idx| {
                try writer.print("    [{d}] {}\n", .{ idx, std.fmt.fmtSliceHexLower(&entry) });
            }
        }
    }

    if (!printed_any) {
        try writer.writeAll("  (All queues empty)\n");
    }
    try writer.writeAll("}");
}
