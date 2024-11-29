const std = @import("std");
const Rho = @import("../pending_reports.zig").Rho;

pub fn format(
    comptime core_count: u32,
    self: *const Rho(core_count),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Rho{\n");
    try writer.writeAll("  Reports:\n");

    for (self.reports, 0..) |report, i| {
        if (report) |r| {
            try writer.print("    Core {d}: {{\n", .{i});
            try writer.print("      hash: {s}\n", .{std.fmt.fmtSliceHexLower(&r.hash)});
            try writer.print("      timeslot: {d}\n", .{r.timeslot});
            try writer.writeAll("    }\n");
        }
    }

    try writer.writeAll("}");
}
