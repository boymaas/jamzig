const std = @import("std");

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.types_fmt);

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
            const span = trace.span(.indented_write);
            defer span.deinit();
            span.debug("Writing {d} bytes with indent level {d}", .{ bytes.len, self.indent_level });

            var written: usize = 0;
            for (bytes) |byte| {
                if (self.at_start) {
                    span.trace("At line start, writing indent", .{});
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
            const span = trace.span(.indent);
            defer span.deinit();
            self.indent_level += 1;
            span.debug("Increased indent to {d}", .{self.indent_level});
        }

        pub fn outdent(self: *Self) void {
            const span = trace.span(.outdent);
            defer span.deinit();
            if (self.indent_level > 0) {
                self.indent_level -= 1;
                span.debug("Decreased indent to {d}", .{self.indent_level});
            } else {
                span.debug("Cannot decrease indent: already at 0", .{});
            }
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
    const span = trace.span(.format_hex);
    defer span.deinit();
    span.debug("Formatting hex value of type {s} (len: {d})", .{ @typeName(@TypeOf(value)), value.len });

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

const ContainerType = enum {
    list, // ArrayList, ArrayListUnmanaged, BoundedArray
    hash_map, // HashMap variants including ArrayHashMap
    none,
};

fn detectStdMemAllocator(comptime T: type) bool {
    return std.mem.indexOf(u8, @typeName(T), "mem.Allocator") != null;
}

fn detectContainerType(comptime T: type) ContainerType {
    const type_name = @typeName(T);
    if (comptime std.mem.indexOf(u8, type_name, "HashMap") != null or
        std.mem.indexOf(u8, type_name, "ArrayHashMap") != null)
    {
        return .hash_map;
    }

    if (std.mem.indexOf(u8, type_name, "ArrayList") != null or
        std.mem.indexOf(u8, type_name, "BoundedArray") != null)
    {
        return .list;
    }
    return .none;
}

fn formatContainer(comptime T: type, value: anytype, writer: anytype) !bool {
    switch (comptime detectContainerType(T)) {
        .list => {
            // Handle array-like containers (ArrayList, BoundedArray)
            const items = if (@hasDecl(T, "items"))
                value.items()
            else if (@hasDecl(T, "constrained"))
                value.constrained()
            else if (@hasDecl(T, "constSlice"))
                value.constSlice()
            else
                @compileError("Container type: " ++ @typeName(T) ++ " does not have items or constrained method");

            if (@hasDecl(T, "capacity")) {
                try writer.print("{s} (len: {d}, capacity: {d})\n", .{
                    @typeName(T),
                    items.len,
                    value.capacity(),
                });
            } else {
                try writer.print("{s} (len: {d})\n", .{
                    @typeName(T),
                    items.len,
                });
            }

            if (items.len > 0) {
                try writer.writeAll("[\n");
                writer.context.indent();
                for (items, 0..) |item, i| {
                    try writer.print("{d}: ", .{i});
                    try formatValue(item, writer);
                    try writer.writeAll("\n");
                }
                writer.context.outdent();
                try writer.writeAll("]\n");
            } else {
                try writer.writeAll("[ <empty> ]");
            }
            return true;
        },
        .hash_map => {
            try writer.print("{s} (count: {d})\n", .{
                @typeName(T),
                value.count(),
            });

            var it = value.iterator();
            if (it.next()) |first| {
                writer.context.indent();

                // Format first entry
                try writer.writeAll("key: ");
                try formatValue(first.key_ptr.*, writer);
                try writer.writeAll("\nvalue: ");
                try formatValue(first.value_ptr.*, writer);
                try writer.writeAll("\n");

                // Format remaining entries
                while (it.next()) |entry| {
                    try writer.writeAll("key: ");
                    try formatValue(entry.key_ptr.*, writer);
                    try writer.writeAll("\nvalue: ");
                    try formatValue(entry.value_ptr.*, writer);
                    try writer.writeAll("\n");
                }
                writer.context.outdent();
            } else {
                try writer.writeAll("<empty>");
            }
            return true;
        },
        .none => return false,
    }
}

pub fn formatValue(value: anytype, writer: anytype) !void {
    const span = trace.span(.format_value);
    defer span.deinit();

    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    span.debug("Formatting value of type: {s}", .{@typeName(T)});

    // never format our allocators
    if (detectStdMemAllocator(T)) {
        span.debug("Skipping allocator formatting", .{});
        return;
    }

    switch (type_info) {
        .@"struct" => |info| {
            const struct_span = span.child(.struct_format);
            defer struct_span.deinit();
            struct_span.debug("Formatting struct with {d} fields", .{info.fields.len});

            // check it's a generic data structure we recognize, if that is the case
            // we can format it in a more human-readable way
            if (try formatContainer(T, value, writer)) return;

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
            const union_span = span.child(.union_format);
            defer union_span.deinit();
            union_span.debug("Formatting union of type {s}", .{@typeName(T)});

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
            const ptr_span = span.child(.pointer_format);
            defer ptr_span.deinit();
            ptr_span.debug("Formatting pointer of type {s}", .{@typeName(T)});

            if (ptr.child == u8 and ptr.size == .Slice) {
                ptr_span.debug("Handling as byte slice", .{});
                try formatHex(value, writer);
            } else {
                switch (ptr.size) {
                    .Slice => {
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
                            try writer.writeAll("]\n");
                        } else {
                            try writer.writeAll("[ <empty> ]");
                        }
                    },
                    .One => {
                        ptr_span.warn("Unsupported pointer size: {s} skipping", .{@typeName(@TypeOf(value))});
                        // try writer.writeAll("ptr(");
                        // try formatValue(value.*, writer);
                        // try writer.writeAll(")");
                    },
                    else => {
                        ptr_span.warn("Unsupported pointer size: {s} skipping", .{@typeName(@TypeOf(value))});
                        // @compileError("Unsupported pointer size: " ++ @typeName(ptr.size));
                    },
                }
            }
        },
        .array => |arr| {
            const arr_span = span.child(.array_format);
            defer arr_span.deinit();
            arr_span.debug("Formatting array of type {s}[{d}]", .{ @typeName(arr.child), arr.len });

            if (arr.child == u8) {
                arr_span.debug("Handling as byte array", .{});
                try formatHex(&value, writer);
            } else {
                try writer.writeAll("[\n");
                writer.context.indent();
                for (
                    value,
                ) |item| {
                    try formatValue(item, writer);
                }
                writer.context.outdent();
                try writer.writeAll("]\n");
            }
        },
        .optional => |_| {
            const opt_span = span.child(.optional_format);
            defer opt_span.deinit();
            opt_span.debug("Formatting optional of type {s}", .{@typeName(T)});

            if (value) |v| {
                opt_span.debug("Optional has value", .{});
                try formatValue(v, writer);
                try writer.writeAll("\n");
            } else {
                opt_span.debug("Optional is null", .{});

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
