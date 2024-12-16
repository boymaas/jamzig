const std = @import("std");
const JamState = @import("../state.zig").JamState;
const Params = @import("../jam_params.zig").Params;

const tfmt = @import("../types/fmt.zig");

pub fn format(
    comptime P: Params,
    self: *const JamState(P),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    const iw = indented_writer.writer();

    try iw.print(
        "JamState(validators_count={d},core_count={d}):\n",
        .{ P.validators_count, P.core_count },
    );
    iw.context.indent();

    inline for (std.meta.fields(@TypeOf(self.*))) |field| {
        try iw.print("{s}: ", .{field.name});
        try tfmt.formatValue(@field(self.*, field.name), iw);
    }
}

test "JamStateFormat" {
    const allocator = std.testing.allocator;
    const TINY = @import("../jam_params.zig").TINY_PARAMS;

    var state = try JamState(TINY).init(allocator);
    defer state.deinit(allocator);

    // Print the JSON string (you can comment this out if you don't want to print)
    std.debug.print("\n{s}\n", .{state});
}
