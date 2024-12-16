const std = @import("std");
const tfmt = @import("../types/fmt.zig");
const Xi = @import("../accumulated_reports.zig").Xi;

pub fn format(
    comptime epoch_size: usize,
    self: *const Xi(epoch_size),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    // Count total entries for header
    var total_entries: usize = 0;
    for (self.entries) |slot_entries| {
        total_entries += slot_entries.count();
    }

    try iw.print("Xi (epoch_size: {d}):\n", .{epoch_size});
    iw.context.indent();
    defer iw.context.outdent();

    try iw.print("total_entries: {d}\n", .{total_entries});

    // Format each non-empty slot
    for (self.entries, 0..) |slot_entries, slot| {
        if (slot_entries.count() > 0) {
            try iw.print("slot {d}:\n", .{slot});
            iw.context.indent();

            try tfmt.formatValue(slot_entries, iw);

            iw.context.outdent();
        }
    }
}

// Test helper to demonstrate formatting
test "Xi format demo" {
    // Setup test data
    const epoch_size = 4;
    var xi = Xi(epoch_size).init(std.testing.allocator);
    defer xi.deinit();

    // Add some test entries
    const work_report_hash1 = [_]u8{0xA1} ++ [_]u8{0} ** 31;
    const segment_root1 = [_]u8{0xB1} ++ [_]u8{0} ** 31;
    const work_report_hash2 = [_]u8{0xA2} ++ [_]u8{0} ** 31;
    const segment_root2 = [_]u8{0xB2} ++ [_]u8{0} ** 31;

    try xi.addEntryToTimeSlot(1, work_report_hash1, segment_root1);
    try xi.addEntryToTimeSlot(1, work_report_hash2, segment_root2);
    try xi.addEntryToTimeSlot(3, work_report_hash2, segment_root2);

    // Print formatted output
    std.debug.print("\n{}\n", .{xi});
}
