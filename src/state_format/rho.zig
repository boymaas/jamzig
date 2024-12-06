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
            const hash = r.cached_hash orelse try r.hash_uncached(self.allocator);
            try writer.print("    Core {d}: {{\n", .{i});
            try writer.print("      hash: {s}\n", .{std.fmt.fmtSliceHexLower(&hash)});
            try writer.print("      timeout: {d}\n", .{r.assignment.timeout});
            try writer.writeAll("    }\n");
        }
    }

    try writer.writeAll("}");
}
