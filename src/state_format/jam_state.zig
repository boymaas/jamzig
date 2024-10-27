const std = @import("std");
const JamState = @import("../state.zig").JamState;
const Params = @import("../jam_params.zig").Params;

fn IndentWriter(comptime Writer: type) type {
    return struct {
        wrapped: Writer,
        indent: []const u8,
        at_start: bool,

        const Self = @This();
        pub const Error = anyerror;

        pub fn init(wrapped: Writer, indent: []const u8) Self {
            return .{
                .wrapped = wrapped,
                .indent = indent,
                .at_start = true,
            };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            var written: usize = 0;

            for (bytes) |byte| {
                if (self.at_start) {
                    written += try self.wrapped.write(self.indent);
                    self.at_start = false;
                }
                written += try self.wrapped.write(&[_]u8{byte});
                // Only set at_start to true when we actually see a newline
                if (byte == '\n') {
                    self.at_start = true;
                }
            }

            // We need to return the number of bytes written as expected
            // by the caller. This is not the actual number of bytes written but an indicator
            // that we finished writing. This happens when we have written all bytes.
            return bytes.len;
        }

        pub fn writer(self: *Self) std.io.Writer(*Self, Error, write) {
            return .{ .context = self };
        }
    };
}

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
    inline for (std.meta.fields(@TypeOf(self.*))) |field| {
        try writer.print(" \x1b[1;37m{s}\x1b[0m:\n", .{field.name});
        // Create indented writer and ensure first line is indented
        var indent_writer = IndentWriter(@TypeOf(writer)).init(writer, "   ");
        // Force the first line to be indented
        indent_writer.at_start = true;
        try std.fmt.format(indent_writer.writer(), "{any}", .{@field(self, field.name)});
        try writer.writeByte('\n');
    }
    try writer.writeAll("}");
}
