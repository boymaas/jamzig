const std = @import("std");
const Chi = @import("../services_priviledged.zig").Chi;

pub fn format(
    chi: anytype,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    
    try writer.writeAll("Chi {\n");
    try writer.print("  manager: {?},\n", .{chi.manager});
    try writer.print("  assign: {?},\n", .{chi.assign});
    try writer.print("  designate: {?},\n", .{chi.designate});
    try writer.writeAll("  always_accumulate: {\n");
    
    var it = chi.always_accumulate.iterator();
    while (it.next()) |entry| {
        try writer.print("    {}: {}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
    
    try writer.writeAll("  }\n");
    try writer.writeAll("}");
}
