const std = @import("std");
const types = @import("../types.zig");

pub const ReflectionDiffOptions = struct {
    path_context: []const u8 = "",
    max_depth: usize = 20,
    show_deltas: bool = true,
    format_hex: bool = true,
    ignore_fields: []const []const u8 = &.{},
};

pub const DiffEntry = struct {
    path: []const u8,
    actual_value: []const u8,
    expected_value: []const u8,
    delta: ?i64,
    type_name: []const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.actual_value);
        allocator.free(self.expected_value);
        allocator.free(self.type_name);
        self.* = undefined;
    }
};

pub const ReflectionDiffResult = struct {
    entries: std.ArrayList(DiffEntry),
    allocator: std.mem.Allocator,

    pub fn hasChanges(self: *const @This()) bool {
        return self.entries.items.len > 0;
    }

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        if (self.entries.items.len == 0) {
            try writer.writeAll("\x1b[32m✅ No differences found\x1b[0m\n");
            return;
        }

        try writer.print("\n\x1b[1;36m=== REFLECTION DIFF ({d} differences) ===\x1b[0m\n\n", .{self.entries.items.len});

        var current_component: ?[]const u8 = null;

        for (self.entries.items) |entry| {
            const component = extractComponent(entry.path);

            if (current_component == null or !std.mem.eql(u8, current_component.?, component)) {
                if (current_component != null) try writer.writeAll("\n");
                try writer.print("\x1b[1;33m━━━ {s} ━━━\x1b[0m\n", .{component});
                current_component = component;
            }

            try writer.print("  \x1b[31m✗\x1b[0m {s}\n", .{entry.path});
            try writer.print("    \x1b[90mActual:  \x1b[0m \x1b[36m{s}\x1b[0m \x1b[90m({s})\x1b[0m\n", .{ entry.actual_value, entry.type_name });
            try writer.print("    \x1b[90mExpected:\x1b[0m \x1b[32m{s}\x1b[0m \x1b[90m({s})\x1b[0m\n", .{ entry.expected_value, entry.type_name });

            if (entry.delta) |delta| {
                const symbol = if (delta > 0) "+" else "";
                try writer.print("    \x1b[90mDelta:   \x1b[0m \x1b[33m{s}{d}\x1b[0m\n", .{ symbol, delta });
            }
            try writer.writeAll("\n");
        }

        try writer.print("\x1b[1;36m━━━ END REFLECTION DIFF ━━━\x1b[0m\n", .{});
    }

    pub fn deinit(self: *@This()) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
        self.* = undefined;
    }
};

fn extractComponent(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, ".")) |dot_pos| {
        return path[0..dot_pos];
    }
    return path;
}

fn shouldIgnoreField(field_name: []const u8, options: ReflectionDiffOptions) bool {
    for (options.ignore_fields) |ignore| {
        if (std.mem.eql(u8, field_name, ignore)) {
            return true;
        }
    }
    return false;
}

fn isHashType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |arr| arr.child == u8 and (arr.len == 32 or arr.len == 64 or arr.len == 96 or arr.len == 144 or arr.len == 784),
        else => false,
    };
}

const ContainerType = enum {
    hash_map,
    array_list,
    none,
};

fn isWalkableType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info != .@"opaque" and
        type_info != .@"fn" and
        type_info != .void and
        type_info != .type;
}

fn detectContainerType(comptime T: type) ContainerType {
    @setEvalBranchQuota(10_000);
    const type_name = @typeName(T);

    if (std.mem.indexOf(u8, type_name, "HashMap") != null or
        std.mem.indexOf(u8, type_name, "ArrayHashMap") != null)
    {
        return .hash_map;
    }

    if (std.mem.indexOf(u8, type_name, "ArrayList") != null or
        std.mem.indexOf(u8, type_name, "BoundedArray") != null)
    {
        return .array_list;
    }

    return .none;
}

pub fn diffBasedOnReflection(
    comptime T: type,
    allocator: std.mem.Allocator,
    expected: T,
    actual: T,
    options: ReflectionDiffOptions,
) !ReflectionDiffResult {
    var entries = std.ArrayList(DiffEntry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    try walkAndCompare(T, allocator, expected, actual, options.path_context, 0, options, &entries);

    return ReflectionDiffResult{
        .entries = entries,
        .allocator = allocator,
    };
}

fn walkAndCompare(
    comptime T: type,
    allocator: std.mem.Allocator,
    expected: T,
    actual: T,
    path: []const u8,
    depth: usize,
    options: ReflectionDiffOptions,
    entries: *std.ArrayList(DiffEntry),
) !void {
    @setEvalBranchQuota(10_000);

    comptime {
        const type_info = @typeInfo(T);
        if (type_info == .@"opaque" or type_info == .@"fn" or type_info == .void or type_info == .type) {
            return;
        }
    }

    if (depth >= options.max_depth) {
        return;
    }

    const type_info = @typeInfo(T);

    switch (type_info) {
        .int, .comptime_int => {
            if (expected != actual) {
                const delta: ?i64 = if (options.show_deltas) blk: {
                    const type_info_int = @typeInfo(T).int;
                    if (type_info_int.signedness == .unsigned and type_info_int.bits > 63) {
                        if (expected > std.math.maxInt(i64) or actual > std.math.maxInt(i64)) {
                            break :blk null;
                        }
                    }
                    const exp_i64 = @as(i64, @intCast(expected));
                    const act_i64 = @as(i64, @intCast(actual));
                    break :blk act_i64 - exp_i64;
                } else null;

                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try std.fmt.allocPrint(allocator, "{d}", .{actual}),
                    .expected_value = try std.fmt.allocPrint(allocator, "{d}", .{expected}),
                    .delta = delta,
                    .type_name = try allocator.dupe(u8, @typeName(T)),
                });
            }
        },

        .float, .comptime_float => {
            if (expected != actual) {
                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try std.fmt.allocPrint(allocator, "{d}", .{actual}),
                    .expected_value = try std.fmt.allocPrint(allocator, "{d}", .{expected}),
                    .delta = null,
                    .type_name = try allocator.dupe(u8, @typeName(T)),
                });
            }
        },

        .bool => {
            if (expected != actual) {
                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try allocator.dupe(u8, if (actual) "true" else "false"),
                    .expected_value = try allocator.dupe(u8, if (expected) "true" else "false"),
                    .delta = null,
                    .type_name = try allocator.dupe(u8, "bool"),
                });
            }
        },

        .@"enum" => {
            if (expected != actual) {
                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(actual)}),
                    .expected_value = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(expected)}),
                    .delta = null,
                    .type_name = try allocator.dupe(u8, @typeName(T)),
                });
            }
        },

        .array => |arr| {
            if (isHashType(T) and options.format_hex) {
                const exp_bytes: []const u8 = std.mem.asBytes(&expected);
                const act_bytes: []const u8 = std.mem.asBytes(&actual);
                if (!std.mem.eql(u8, exp_bytes, act_bytes)) {
                    try entries.append(.{
                        .path = try allocator.dupe(u8, path),
                        .actual_value = try std.fmt.allocPrint(allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(act_bytes)}),
                        .expected_value = try std.fmt.allocPrint(allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(exp_bytes)}),
                        .delta = null,
                        .type_name = try std.fmt.allocPrint(allocator, "[{d}]u8", .{arr.len}),
                    });
                }
            } else {
                if (comptime isWalkableType(arr.child)) {
                    for (0..arr.len) |i| {
                        const elem_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                        defer allocator.free(elem_path);
                        try walkAndCompare(arr.child, allocator, expected[i], actual[i], elem_path, depth + 1, options, entries);
                    }
                }
            }
        },

        .@"struct" => |_| {
            const container_type = comptime detectContainerType(T);

            switch (container_type) {
                .hash_map => {
                    try diffHashMap(T, allocator, expected, actual, path, depth, options, entries);
                },
                .array_list => {
                    try diffArrayList(T, allocator, expected, actual, path, depth, options, entries);
                },
                .none => {
                    inline for (std.meta.fields(T)) |field| {
                        if (!shouldIgnoreField(field.name, options)) {
                            if (comptime !isWalkableType(field.type)) {
                                continue;
                            }

                            const field_path = if (path.len == 0)
                                try allocator.dupe(u8, field.name)
                            else
                                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, field.name });
                            defer allocator.free(field_path);

                            try walkAndCompare(
                                field.type,
                                allocator,
                                @field(expected, field.name),
                                @field(actual, field.name),
                                field_path,
                                depth + 1,
                                options,
                                entries,
                            );
                        }
                    }
                },
            }
        },

        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8 and options.format_hex) {
                        if (!std.mem.eql(u8, expected, actual)) {
                            const actual_hex = if (actual.len <= 32)
                                try std.fmt.allocPrint(allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(actual)})
                            else
                                try std.fmt.allocPrint(allocator, "0x{s}... (len: {d})", .{ std.fmt.fmtSliceHexLower(actual[0..32]), actual.len });

                            const expected_hex = if (expected.len <= 32)
                                try std.fmt.allocPrint(allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(expected)})
                            else
                                try std.fmt.allocPrint(allocator, "0x{s}... (len: {d})", .{ std.fmt.fmtSliceHexLower(expected[0..32]), expected.len });

                            try entries.append(.{
                                .path = try allocator.dupe(u8, path),
                                .actual_value = actual_hex,
                                .expected_value = expected_hex,
                                .delta = null,
                                .type_name = try allocator.dupe(u8, "[]u8"),
                            });
                        }
                    } else {
                        if (expected.len != actual.len) {
                            try entries.append(.{
                                .path = try allocator.dupe(u8, path),
                                .actual_value = try std.fmt.allocPrint(allocator, "length={d}", .{actual.len}),
                                .expected_value = try std.fmt.allocPrint(allocator, "length={d}", .{expected.len}),
                                .delta = @as(i64, @intCast(actual.len)) - @as(i64, @intCast(expected.len)),
                                .type_name = try std.fmt.allocPrint(allocator, "[]{s}", .{@typeName(ptr.child)}),
                            });
                        } else {
                            if (comptime isWalkableType(ptr.child)) {
                                for (0..expected.len) |i| {
                                    const elem_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                                    defer allocator.free(elem_path);
                                    try walkAndCompare(ptr.child, allocator, expected[i], actual[i], elem_path, depth + 1, options, entries);
                                }
                            }
                        }
                    }
                },
                .one => {
                    if (comptime isWalkableType(ptr.child)) {
                        try walkAndCompare(ptr.child, allocator, expected.*, actual.*, path, depth + 1, options, entries);
                    }
                },
                else => {},
            }
        },

        .optional => {
            if (expected == null and actual == null) {
                return;
            }
            if (expected == null and actual != null) {
                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try allocator.dupe(u8, "<non-null>"),
                    .expected_value = try allocator.dupe(u8, "null"),
                    .delta = null,
                    .type_name = try allocator.dupe(u8, @typeName(T)),
                });
                return;
            }
            if (expected != null and actual == null) {
                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try allocator.dupe(u8, "null"),
                    .expected_value = try allocator.dupe(u8, "<non-null>"),
                    .delta = null,
                    .type_name = try allocator.dupe(u8, @typeName(T)),
                });
                return;
            }

            const ChildType = @typeInfo(T).optional.child;
            if (comptime isWalkableType(ChildType)) {
                try walkAndCompare(ChildType, allocator, expected.?, actual.?, path, depth + 1, options, entries);
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                return;
            }

            const expected_tag = std.meta.activeTag(expected);
            const actual_tag = std.meta.activeTag(actual);

            if (expected_tag != actual_tag) {
                try entries.append(.{
                    .path = try allocator.dupe(u8, path),
                    .actual_value = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(actual_tag)}),
                    .expected_value = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(expected_tag)}),
                    .delta = null,
                    .type_name = try allocator.dupe(u8, @typeName(T)),
                });
            } else {
                inline for (union_info.fields) |field| {
                    if (expected_tag == @field(@typeInfo(T).@"union".tag_type.?, field.name)) {
                        if (field.type != void and comptime isWalkableType(field.type)) {
                            try walkAndCompare(
                                field.type,
                                allocator,
                                @field(expected, field.name),
                                @field(actual, field.name),
                                path,
                                depth + 1,
                                options,
                                entries,
                            );
                        }
                    }
                }
            }
        },

        else => {},
    }
}

fn formatKeyPath(allocator: std.mem.Allocator, path: []const u8, key: anytype) ![]u8 {
    const KeyType = @TypeOf(key);
    const key_type_info = @typeInfo(KeyType);

    if (key_type_info == .array and key_type_info.array.child == u8) {
        const key_bytes: []const u8 = &key;

        var all_ascii = true;
        for (key_bytes) |byte| {
            if (byte < 32 or byte > 126) {
                all_ascii = false;
                break;
            }
        }

        if (all_ascii) {
            return std.fmt.allocPrint(allocator, "{s}[0x{s} \"{s}\"]", .{
                path,
                std.fmt.fmtSliceHexLower(key_bytes),
                key_bytes,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{s}[0x{s}]", .{
                path,
                std.fmt.fmtSliceHexLower(key_bytes),
            });
        }
    }

    return std.fmt.allocPrint(allocator, "{s}[{any}]", .{ path, key });
}

fn diffHashMap(
    comptime T: type,
    allocator: std.mem.Allocator,
    expected: T,
    actual: T,
    path: []const u8,
    depth: usize,
    options: ReflectionDiffOptions,
    entries: *std.ArrayList(DiffEntry),
) !void {
    @setEvalBranchQuota(10_000);

    const KeyType = blk: {
        var dummy_it = expected.iterator();
        const EntryOptType = @TypeOf(dummy_it.next());
        const entry_info = @typeInfo(EntryOptType);
        if (entry_info != .optional) @compileError("Expected optional from iterator");
        const EntryType = entry_info.optional.child;
        const entry_struct_info = @typeInfo(EntryType);
        if (entry_struct_info != .@"struct") @compileError("Expected struct entry");
        const KeyPtrType = entry_struct_info.@"struct".fields[0].type;
        const key_ptr_info = @typeInfo(KeyPtrType);
        break :blk key_ptr_info.pointer.child;
    };

    const ValueType = blk: {
        var dummy_it = expected.iterator();
        const EntryOptType = @TypeOf(dummy_it.next());
        const entry_info = @typeInfo(EntryOptType);
        const EntryType = entry_info.optional.child;
        const entry_struct_info = @typeInfo(EntryType);
        const ValuePtrType = entry_struct_info.@"struct".fields[1].type;
        const value_ptr_info = @typeInfo(ValuePtrType);
        break :blk value_ptr_info.pointer.child;
    };

    var all_keys = std.AutoHashMap(KeyType, void).init(allocator);
    defer all_keys.deinit();

    try all_keys.ensureTotalCapacity(@intCast(expected.count() + actual.count()));

    var exp_it = expected.iterator();
    while (exp_it.next()) |entry| {
        all_keys.putAssumeCapacity(entry.key_ptr.*, {});
    }

    var act_it = actual.iterator();
    while (act_it.next()) |entry| {
        all_keys.putAssumeCapacity(entry.key_ptr.*, {});
    }

    var key_it = all_keys.keyIterator();
    while (key_it.next()) |key_ptr| {
        const key = key_ptr.*;
        const exp_value = expected.get(key);
        const act_value = actual.get(key);

        const key_path = try formatKeyPath(allocator, path, key);
        defer allocator.free(key_path);

        if (exp_value != null and act_value == null) {
            try entries.append(.{
                .path = try allocator.dupe(u8, key_path),
                .actual_value = try allocator.dupe(u8, "MISSING"),
                .expected_value = try allocator.dupe(u8, "<exists>"),
                .delta = null,
                .type_name = try allocator.dupe(u8, @typeName(ValueType)),
            });
        } else if (exp_value == null and act_value != null) {
            try entries.append(.{
                .path = try allocator.dupe(u8, key_path),
                .actual_value = try allocator.dupe(u8, "<exists>"),
                .expected_value = try allocator.dupe(u8, "MISSING"),
                .delta = null,
                .type_name = try allocator.dupe(u8, @typeName(ValueType)),
            });
        } else if (exp_value != null and act_value != null) {
            if (comptime isWalkableType(ValueType)) {
                try walkAndCompare(
                    ValueType,
                    allocator,
                    exp_value.?,
                    act_value.?,
                    key_path,
                    depth + 1,
                    options,
                    entries,
                );
            }
        }
    }
}

fn diffArrayList(
    comptime T: type,
    allocator: std.mem.Allocator,
    expected: T,
    actual: T,
    path: []const u8,
    depth: usize,
    options: ReflectionDiffOptions,
    entries: *std.ArrayList(DiffEntry),
) !void {
    const items_exp = if (@hasField(T, "items"))
        expected.items
    else if (@hasDecl(T, "constSlice"))
        expected.constSlice()
    else
        @compileError("ArrayList type does not have items field or constSlice method");

    const items_act = if (@hasField(T, "items"))
        actual.items
    else if (@hasDecl(T, "constSlice"))
        actual.constSlice()
    else
        @compileError("ArrayList type does not have items field or constSlice method");

    if (items_exp.len != items_act.len) {
        try entries.append(.{
            .path = try std.fmt.allocPrint(allocator, "{s}.length", .{path}),
            .actual_value = try std.fmt.allocPrint(allocator, "{d}", .{items_act.len}),
            .expected_value = try std.fmt.allocPrint(allocator, "{d}", .{items_exp.len}),
            .delta = @as(i64, @intCast(items_act.len)) - @as(i64, @intCast(items_exp.len)),
            .type_name = try allocator.dupe(u8, "usize"),
        });
    }

    const min_len = @min(items_exp.len, items_act.len);
    const ChildType = @TypeOf(items_exp[0]);

    if (comptime isWalkableType(ChildType)) {
        for (0..min_len) |i| {
            const elem_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
            defer allocator.free(elem_path);
            try walkAndCompare(ChildType, allocator, items_exp[i], items_act[i], elem_path, depth + 1, options, entries);
        }
    }
}
