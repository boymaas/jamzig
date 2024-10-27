const std = @import("std");
const Theta = @import("../available_reports.zig").Theta;

pub fn format(
    comptime epoch_size: usize,
    self: *const Theta(epoch_size),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Theta{\n");
    for (self.entries, 0..) |slot_entries, i| {
        if (slot_entries.items.len > 0) {
            try writer.print("  Slot {d}: {d} reports\n", .{ i, slot_entries.items.len });
            for (slot_entries.items) |entry| {
                try writer.print("    Report: {s}\n", .{std.fmt.fmtSliceHexLower(&entry.work_report.package_spec.hash)});
                try writer.writeAll("    Dependencies: ");
                var it = entry.dependencies.iterator();
                while (it.next()) |dep| {
                    try writer.print("{s} ", .{std.fmt.fmtSliceHexLower(&dep.key_ptr.*)});
                }
                try writer.writeAll("\n");
            }
        }
    }
    try writer.writeAll("}");
}
