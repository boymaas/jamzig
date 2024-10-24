const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
pub const decoder = @import("codec/decoder.zig");
pub const encoder = @import("codec/encoder.zig");
const Scanner = @import("codec/scanner.zig").Scanner;
const trace = @import("tracing.zig").src;

pub fn Deserialized(T: anytype) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

//  ____                      _       _ _
// |  _ \  ___  ___  ___ _ __(_) __ _| (_)_______
// | | | |/ _ \/ __|/ _ \ '__| |/ _` | | |_  / _ \
// | |_| |  __/\__ \  __/ |  | | (_| | | |/ /  __/
// |____/ \___||___/\___|_|  |_|\__,_|_|_/___\___|

pub fn deserialize(comptime T: type, comptime params: anytype, parent_allocator: std.mem.Allocator, data: []u8) !Deserialized(T) {
    trace(@src(), "deserialize: start", .{});
    defer trace(@src(), "deserialize: end", .{});

    var result = Deserialized(T){
        .arena = try parent_allocator.create(ArenaAllocator),
        .value = undefined,
    };
    errdefer parent_allocator.destroy(result.arena);
    result.arena.* = ArenaAllocator.init(parent_allocator);
    errdefer result.arena.deinit();

    var scanner = Scanner.initCompleteInput(data);
    result.value = try recursiveDeserializeLeaky(T, params, result.arena.allocator(), &scanner);

    return result;
}

/// `scanner_or_reader` must be either a `*std.json.Scanner` with complete input or a `*std.json.Reader`.
/// Allocations made during this operation are not carefully tracked and may not be possible to individually clean up.
/// It is recommended to use a `std.heap.ArenaAllocator` or similar.
fn recursiveDeserializeLeaky(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, scanner: *Scanner) !T {
    trace(@src(), "start - type: {s}", .{@typeName(T)});
    defer trace(@src(), "recursiveDeserializeLeaky: end - type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
        .bool => {
            trace(@src(), "handling boolean", .{});
            const byte = try scanner.readByte();
            return byte != 0;
        },
        .int => |intInfo| {
            trace(@src(), "handling integer", .{});
            inline for (.{ u8, u16, u32, u64, u128 }) |t| {
                if (intInfo.bits == @bitSizeOf(t)) {
                    const integer = decoder.decodeFixedLengthInteger(t, try scanner.readBytes(intInfo.bits / 8));
                    // trace(@src(), "handling integer: {} => {}", .{ @typeName(t), integer });
                    return integer;
                }
            }
            @panic("unhandled integer type");
        },
        .optional => |optionalInfo| {
            const present = try scanner.readByte();
            trace(@src(), "handling optional {d}", .{present});
            if (present == 0) {
                trace(@src(), "handling optional: null", .{});
                return null;
            } else if (present == 1) {
                trace(@src(), "handling optional: present {any}", .{@typeName(optionalInfo.child)});
                return try recursiveDeserializeLeaky(optionalInfo.child, params, allocator, scanner);
            } else {
                return error.InvalidValueForOptional;
            }
        },
        .float => {
            // Handle float deserialization
            @compileError("Float deserialization not implemented yet");
        },
        .@"struct" => |structInfo| {
            trace(@src(), "handling struct", .{});
            const fields = structInfo.fields;
            var result: T = undefined;
            inline for (fields) |field| {
                trace(@src(), "deserializing struct field: {s}", .{field.name});

                const field_type = field.type;
                if (@hasDecl(T, field.name ++ "_size")) {
                    // Special handling for fields with a corresponding _size function
                    // if this function is present we ware using the size from the size function
                    // otherwise we will use the frin the prefex
                    const size_fn = @field(T, field.name ++ "_size");
                    const size = @call(.auto, size_fn, .{params});
                    const slice = try allocator.alloc(std.meta.Child(field_type), size);
                    for (slice) |*item| {
                        item.* = try recursiveDeserializeLeaky(std.meta.Child(field_type), params, allocator, scanner);
                    }
                    @field(result, field.name) = slice;
                } else {
                    const field_value = try recursiveDeserializeLeaky(field_type, params, allocator, scanner);
                    @field(result, field.name) = field_value;
                }
            }
            return result;
        },
        .array => |arrayInfo| {
            if (arrayInfo.sentinel != null) {
                @compileError("Arrays with sentinels are not supported for deserialization");
            }
            return try deserializeArray(arrayInfo.child, arrayInfo.len, scanner);
        },
        .pointer => |pointerInfo| {
            trace(@src(), "handling pointer", .{});
            switch (pointerInfo.size) {
                .Slice => {
                    trace(@src(), "handling slice", .{});
                    const len = try decoder.decodeInteger(scanner.remainingBuffer());
                    try scanner.advanceCursor(len.bytes_read);
                    trace(@src(), "recursiveDeserializeLeaky: slice length: {}", .{len.value});
                    const slice = try allocator.alloc(pointerInfo.child, @intCast(len.value));
                    for (slice) |*item| {
                        item.* = try recursiveDeserializeLeaky(pointerInfo.child, params, allocator, scanner);
                    }
                    return slice;
                },
                .One, .Many, .C => {
                    @compileError("Unsupported pointer type for deserialization: " ++ @typeName(T));
                },
            }
        },
        .@"union" => |unionInfo| {
            trace(@src(), "handling union field: {s}", .{@typeName(T)});

            // unionInfo = struct {
            //     layout: ContainerLayout,
            //     tag_type: ?type,
            //     fields: []const UnionField,
            //     decls: []const Declaration,
            // };

            // Read the union tag (index) using variable-length encoding
            const tag_value = try decoder.decodeInteger(scanner.remainingBuffer());
            try scanner.advanceCursor(tag_value.bytes_read);

            inline for (unionInfo.fields, 0..) |field, idx| {
                if (tag_value.value == idx) {
                    trace(@src(), "union field: {s}", .{field.name});

                    // Check if the active field's type is void
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    } else {
                        // Recursively deserialize the active field
                        const field_value: []u8 = try recursiveDeserializeLeaky(field.type, params, allocator, scanner);
                        return @unionInit(T, field.name, field_value);
                    }
                }
            }

            return error.InvalidUnionTag;
        },

        else => {
            @compileError("Unsupported type for deserialization: " ++ @typeName(T));
        },
    }
}

fn deserializeArray(comptime T: type, comptime len: usize, scanner: *Scanner) ![len]T {
    trace(@src(), "deserializeArray: start - type: {s}, length: {}", .{ @typeName(T), len });
    defer trace(@src(), "deserializeArray: end", .{});

    var result: [len]T = undefined;
    const bytes_to_read = @sizeOf(T) * len;
    const data = try scanner.readBytes(bytes_to_read);

    // Copy the read bytes into the result array
    @memcpy(&result, data.ptr);

    return result;
}

//  ____            _       _ _
// / ___|  ___ _ __(_) __ _| (_)_______
// \___ \ / _ \ '__| |/ _` | | |_  / _ \
//  ___) |  __/ |  | | (_| | | |/ /  __/
// |____/ \___|_|  |_|\__,_|_|_/___\___|

pub fn serialize(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    try recursiveSerializeLeaky(T, params, writer, value);
}

pub fn serializeAlloc(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, value: T) ![]u8 {
    trace(@src(), "serialize: start", .{});
    defer trace(@src(), "serialize: end", .{});

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try recursiveSerializeLeaky(T, params, list.writer(), value);

    return list.toOwnedSlice();
}

fn recursiveSerializeLeaky(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    trace(@src(), "start - type: {s}", .{@typeName(T)});
    defer trace(@src(), "recursiveSerializeLeaky: end - type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
        .bool => {
            trace(@src(), "handling boolean", .{});
            try writer.writeByte(if (value) 1 else 0);
        },
        .int => |intInfo| {
            trace(@src(), "handling integer", .{});
            inline for (.{ u8, u16, u32, u64, u128 }) |t| {
                if (intInfo.bits == @bitSizeOf(t)) {
                    var buffer: [intInfo.bits / 8]u8 = undefined;
                    std.mem.writeInt(t, &buffer, value, .little);
                    try writer.writeAll(&buffer);
                    return;
                }
            }
            @panic("unhandled integer type");
        },
        .optional => |optionalInfo| {
            if (value) |v| {
                try writer.writeByte(1);
                try recursiveSerializeLeaky(optionalInfo.child, params, writer, v);
            } else {
                try writer.writeByte(0);
            }
        },
        .float => {
            @compileError("Float serialization not implemented yet");
        },
        .@"struct" => |structInfo| {
            trace(@src(), "handling struct", .{});
            inline for (structInfo.fields) |field| {
                trace(@src(), "serializing struct field: {s}", .{field.name});
                const field_value = @field(value, field.name);
                const field_type = field.type;

                if (@hasDecl(T, field.name ++ "_size")) {
                    const size_fn = @field(T, field.name ++ "_size");
                    const size = @call(.auto, size_fn, .{params});
                    for (field_value[0..size]) |item| {
                        try recursiveSerializeLeaky(std.meta.Child(field_type), params, writer, item);
                    }
                } else {
                    try recursiveSerializeLeaky(field_type, params, writer, field_value);
                }
            }
        },
        .array => |arrayInfo| {
            if (arrayInfo.sentinel != null) {
                @compileError("Arrays with sentinels are not supported for serialization");
            }
            try serializeArray(arrayInfo.child, arrayInfo.len, writer, value);
        },
        .pointer => |pointerInfo| {
            trace(@src(), "handling pointer", .{});
            switch (pointerInfo.size) {
                .Slice => {
                    trace(@src(), "handling slice", .{});
                    try writer.writeAll(encoder.encodeInteger(value.len).as_slice());
                    for (value) |item| {
                        try recursiveSerializeLeaky(pointerInfo.child, params, writer, item);
                    }
                },
                .One, .Many, .C => {
                    @compileError("Unsupported pointer type for serialization: " ++ @typeName(T));
                },
            }
        },
        .@"union" => |unionInfo| {
            trace(@src(), "handling union field: {s}", .{@typeName(T)});
            const tag = std.meta.activeTag(value);
            const tag_value = @intFromEnum(tag);
            try writer.writeAll(encoder.encodeInteger(tag_value).as_slice());

            inline for (unionInfo.fields) |field| {
                if (std.mem.eql(u8, @tagName(tag), field.name)) {
                    if (field.type == void) {
                        // No need to serialize void fields
                    } else {
                        const field_value = @field(value, field.name);
                        try recursiveSerializeLeaky(field.type, params, writer, field_value);
                    }
                    break;
                }
            }
        },
        else => {
            @compileError("Unsupported type for serialization: " ++ @typeName(T));
        },
    }
}

pub fn serializeArray(comptime T: type, comptime len: usize, writer: anytype, value: [len]T) !void {
    trace(@src(), "serializeArray: start - type: {s}, length: {}", .{ @typeName(T), len });
    defer trace(@src(), "serializeArray: end", .{});

    const bytes = std.mem.asBytes(&value);
    try writer.writeAll(bytes);
}

/// Serializes a slice as an array without adding a length prefix to the output.
/// This function is useful when you need to serialize a slice of known length
/// or when the length information is stored separately.
///
/// Note: This differs from the standard slice serialization, which typically
/// includes a length prefix. Use this function only when you're certain that
/// the receiver knows the expected length of the data.
///
/// Params:
///   T: The type of elements in the slice
///   writer: The writer to which the serialized data will be written
///   value: The slice to be serialized
///
/// Returns: An error if the write operation fails
pub fn serializeSliceAsArray(comptime T: type, writer: anytype, value: []const T) !void {
    trace(@src(), "serializeSliceAsArray: start - type: {s}, length: {}", .{ @typeName(@TypeOf(value)), value.len });
    defer trace(@src(), "serializeSliceAsArray: end", .{});

    for (value) |item| {
        try recursiveSerializeLeaky(T, .{}, writer, item);
    }
}

// Tests
comptime {
    _ = @import("codec/tests.zig");
    _ = @import("codec/encoder/tests.zig");
    _ = @import("codec/decoder/tests.zig");
    _ = @import("codec/encoder.zig");
}
