const std = @import("std");
const Psi = @import("../disputes.zig").Psi;

pub fn format(
    self: *const Psi,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Psi{\n");
    
    if (self.good_set.count() > 0) {
        try writer.writeAll("  Good Set:\n");
        var good_it = self.good_set.keyIterator();
        while (good_it.next()) |key| {
            try writer.print("    {s}\n", .{std.fmt.fmtSliceHexLower(&key.*)});
        }
    }

    if (self.bad_set.count() > 0) {
        try writer.writeAll("  Bad Set:\n");
        var bad_it = self.bad_set.keyIterator();
        while (bad_it.next()) |key| {
            try writer.print("    {s}\n", .{std.fmt.fmtSliceHexLower(&key.*)});
        }
    }

    if (self.wonky_set.count() > 0) {
        try writer.writeAll("  Wonky Set:\n");
        var wonky_it = self.wonky_set.keyIterator();
        while (wonky_it.next()) |key| {
            try writer.print("    {s}\n", .{std.fmt.fmtSliceHexLower(&key.*)});
        }
    }

    if (self.punish_set.count() > 0) {
        try writer.writeAll("  Punish Set:\n");
        var punish_it = self.punish_set.keyIterator();
        while (punish_it.next()) |key| {
            try writer.print("    {s}\n", .{std.fmt.fmtSliceHexLower(&key.*)});
        }
    }

    try writer.writeAll("}");
}
