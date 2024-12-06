const std = @import("std");

pub fn format(
    psi: anytype,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Psi {\n");
    try writer.writeAll("  good_set: {\n");
    for (psi.good_set.keys()) |key| {
        try writer.print("    {x}\n", .{key});
    }
    try writer.writeAll("  },\n");

    try writer.writeAll("  bad_set: {\n");
    for (psi.bad_set.keys()) |key| {
        try writer.print("    {x}\n", .{key});
    }
    try writer.writeAll("  },\n");

    try writer.writeAll("  wonky_set: {\n");
    for (psi.wonky_set.keys()) |key| {
        try writer.print("    {x}\n", .{key});
    }
    try writer.writeAll("  },\n");

    try writer.writeAll("  punish_set: {\n");
    for (psi.punish_set.keys()) |key| {
        try writer.print("    {x}\n", .{key});
    }
    try writer.writeAll("  }\n");
    try writer.writeAll("}");
}
