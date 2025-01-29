const std = @import("std");
const tfmt = @import("../types/fmt.zig");
const types = @import("../types.zig");
const RecentHistory = @import("../recent_blocks.zig").RecentHistory;

pub fn format(
    self: *const RecentHistory,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.print("RecentHistory\n", .{});
    iw.context.indent();
    try iw.print("max_blocks: {d}\n", .{self.max_blocks});

    if (self.blocks.items.len > 0) {
        try iw.writeAll("blocks:\n");
        iw.context.indent();
        try tfmt.formatValue(self.blocks.items, iw);
        iw.context.outdent();
    } else {
        try iw.writeAll("blocks: <empty>\n");
    }
}

// Test helper to demonstrate formatting
test "RecentHistory format demo" {
    const allocator = std.testing.allocator;
    var history = @import("../recent_blocks.zig").RecentHistory.init(allocator, 3) catch unreachable;
    defer history.deinit();

    // Create test block
    const block_info = types.BlockInfo{
        .header_hash = [_]u8{0xA1} ++ [_]u8{0} ** 31,
        .state_root = [_]u8{0xB1} ++ [_]u8{0} ** 31,
        .beefy_mmr = try allocator.dupe(?[32]u8, &.{
            [_]u8{0xC1} ++ [_]u8{0} ** 31,
            null,
            [_]u8{0xC3} ++ [_]u8{0} ** 31,
        }),
        .work_reports = try allocator.dupe(@import("../types.zig").ReportedWorkPackage, &.{
            .{
                .hash = [_]u8{0xD1} ++ [_]u8{0} ** 31,
                .exports_root = [_]u8{0xE1} ++ [_]u8{0} ** 31,
            },
            .{
                .hash = [_]u8{0xD2} ++ [_]u8{0} ** 31,
                .exports_root = [_]u8{0xE2} ++ [_]u8{0} ** 31,
            },
        }),
    };

    try history.addBlockInfo(block_info);

    // Print formatted output
    std.debug.print("\n{}\n", .{history});
}
