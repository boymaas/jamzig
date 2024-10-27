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
    var good_it = psi.good_set.keyIterator();
    while (good_it.next()) |key| {
        try writer.print("    {x}\n", .{key.*});
    }
    try writer.writeAll("  },\n");
    
    try writer.writeAll("  bad_set: {\n");
    var bad_it = psi.bad_set.keyIterator();
    while (bad_it.next()) |key| {
        try writer.print("    {x}\n", .{key.*});
    }
    try writer.writeAll("  },\n");
    
    try writer.writeAll("  wonky_set: {\n");
    var wonky_it = psi.wonky_set.keyIterator();
    while (wonky_it.next()) |key| {
        try writer.print("    {x}\n", .{key.*});
    }
    try writer.writeAll("  },\n");
    
    try writer.writeAll("  punish_set: {\n");
    var punish_it = psi.punish_set.keyIterator();
    while (punish_it.next()) |key| {
        try writer.print("    {x}\n", .{key.*});
    }
    try writer.writeAll("  }\n");
    try writer.writeAll("}");
}
