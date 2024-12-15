const std = @import("std");

const tfmt = @import("../types/fmt.zig");
const jam_params = @import("../jam_params.zig");

pub fn format(
    self: *const jam_params.Params,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    const iw = indented_writer.writer();

    try tfmt.formatValue(self.*, iw);
}

test "format JamParams" {
    std.debug.print("\n{s}\n", .{jam_params.TINY_PARAMS});
}
