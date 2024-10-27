const std = @import("std");
const Gamma = @import("../safrole_state.zig").Gamma;

pub fn format(
    self: *const Gamma,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Gamma{\n");
    
    try writer.print("  k: {any}\n", .{self.k});
    try writer.print("  z: {any}\n", .{self.z});
    
    try writer.writeAll("  s: {\n");
    switch (self.s) {
        .tickets => |tickets| try writer.print("    tickets: {any}\n", .{tickets}),
        .keys => |keys| try writer.print("    keys: {any}\n", .{keys}),
    }
    try writer.writeAll("  }\n");
    
    try writer.print("  a: {any}\n", .{self.a});
    
    try writer.writeAll("}");
}
