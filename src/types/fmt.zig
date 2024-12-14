const std = @import("std");

pub fn IndentedWriter(comptime T: type) type {
    return struct {
        wrapped: T,
        indent_level: usize = 0,
        at_start: bool = true,

        const Self = @This();

        const Error = anyerror;

        pub const Writer = std.io.Writer(*Self, Error, indentedWrite);

        pub fn init(wrapped: anytype) Self {
            return .{
                .wrapped = wrapped,
                .indent_level = 0,
                .at_start = true,
            };
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn indentedWrite(self: *Self, bytes: []const u8) Error!usize {
            var written: usize = 0;
            for (bytes) |byte| {
                if (self.at_start) {
                    try self.writeIndent();
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
            return written;
        }

        pub fn writeIndent(self: *Self) Error!void {
            try self.wrapped.writeByteNTimes(' ', self.indent_level * 2);
        }

        pub fn indent(self: *Self) void {
            self.indent_level += 1;
        }

        pub fn outdent(self: *Self) void {
            if (self.indent_level > 0) self.indent_level -= 1;
        }
    };
}

pub fn isHexFormattedType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |arr| arr.child == u8,
        .pointer => |ptr| ptr.child == u8 and ptr.size == .Slice,
        else => false,
    };
}

pub fn formatHex(value: anytype, writer: anytype) !void {
    try writer.writeAll("0x");

    const charset = "0123456789" ++ "abcdef";
    var buf: [2]u8 = undefined;

    for (value) |c| {
        buf[0] = charset[c >> 4];
        buf[1] = charset[c & 15];
        try writer.writeAll(&buf);
    }
    try writer.print(" (len: {d})", .{value.len});
}

pub fn formatValue(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try writer.writeAll(@typeName(T));
            try writer.writeAll("\n");
            writer.context.indent();
            inline for (info.fields) |field| {
                try writer.writeAll(field.name);
                try writer.writeAll(": ");
                try formatValue(@field(value, field.name), writer);
                try writer.writeAll("\n");
            }
            writer.context.outdent();
        },
        .@"union" => |_| {
            try writer.writeAll(@typeName(T));
            try writer.writeAll("\n");
            writer.context.indent();
            try writer.writeAll("tag: ");
            try writer.writeAll(@tagName(value));
            try writer.writeAll("\n");
            try writer.writeAll("payload: ");
            inline for (std.meta.fields(@TypeOf(value))) |field| {
                if (std.meta.activeTag(value) == @field(@TypeOf(value), field.name)) {
                    if (field.type == void) {
                        try writer.writeAll("void");
                    } else {
                        try formatValue(@field(value, field.name), writer);
                    }
                }
            }
            writer.context.outdent();
        },
        .pointer => |ptr| {
            if (ptr.child == u8 and ptr.size == .Slice) {
                try formatHex(value, writer);
            } else {
                if (value.len > 0) {
                    try writer.writeAll("[\n");
                    writer.context.indent();
                    for (value, 0..) |item, idx| {
                        try writer.print("{d}: ", .{idx});
                        writer.context.indent();
                        try formatValue(item, writer);
                        writer.context.outdent();
                    }
                    writer.context.outdent();
                    try writer.writeAll("]");
                } else {
                    try writer.writeAll("[ <empty> ]");
                }
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                try formatHex(&value, writer);
            } else {
                try writer.writeAll("[\n");
                writer.context.indent();
                for (value, 0..) |item, i| {
                    try formatValue(item, writer);
                    if (i < value.len - 1) try writer.writeAll(",");
                    try writer.writeAll("\n");
                }
                writer.context.outdent();
                try writer.writeAll("]");
            }
        },
        .optional => |_| {
            if (value) |v| {
                try formatValue(v, writer);
                try writer.writeAll("\n");
            } else {
                try writer.writeAll("null");
                try writer.writeAll("\n");
            }
        },
        .int, .bool => {
            try std.fmt.format(writer, "{}", .{value});
        },
        .@"enum" => {
            try std.fmt.format(writer, "{s}", .{@tagName(value)});
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

pub fn Format(comptime T: type) type {
    return struct {
        value: T,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            var indented = IndentedWriter(@TypeOf(writer)).init(writer);
            try formatValue(self.value, indented.writer());
        }
    };
}

pub fn format(value: anytype) Format(@TypeOf(value)) {
    return .{ .value = value };
}
