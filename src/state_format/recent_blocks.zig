const std = @import("std");
const RecentHistory = @import("../recent_blocks.zig").RecentHistory;

pub fn format(
    self: *const RecentHistory,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("RecentHistory{\n");
    try writer.print("  max_blocks: {d}\n", .{self.max_blocks});
    
    for (self.blocks.items, 0..) |block, i| {
        try writer.print("  Block {d}:\n", .{i});
        try writer.print("    header_hash: {s}\n", .{std.fmt.fmtSliceHexLower(&block.header_hash)});
        try writer.print("    state_root: {s}\n", .{std.fmt.fmtSliceHexLower(&block.state_root)});
        
        try writer.writeAll("    beefy_mmr: [");
        for (block.beefy_mmr) |maybe_hash| {
            if (maybe_hash) |hash| {
                try writer.print("{s} ", .{std.fmt.fmtSliceHexLower(&hash)});
            } else {
                try writer.writeAll("null ");
            }
        }
        try writer.writeAll("]\n");

        try writer.writeAll("    work_reports: [");
        for (block.work_reports) |hash| {
            try writer.print("{s} ", .{std.fmt.fmtSliceHexLower(&hash)});
        }
        try writer.writeAll("]\n");
    }
    try writer.writeAll("}");
}
