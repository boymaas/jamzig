const std = @import("std");
const JamState = @import("../state.zig").JamState;
const Params = @import("../jam_params.zig").Params;

pub fn format(
    comptime P: Params,
    self: *const JamState(P),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("JamState{\n");

    // Then format each component
    try writer.writeAll("\n  Components:\n");
    inline for (std.meta.fields(@TypeOf(self.*))) |field| {
        try writer.print("    {s}: ", .{field.name});
        try std.fmt.format(writer, "{any}\n", .{@field(self, field.name)});
    }

    try writer.writeAll("\n}");
}
