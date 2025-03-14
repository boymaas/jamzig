const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
pub const decoder = @import("codec/decoder.zig");
pub const encoder = @import("codec/encoder.zig");
const Scanner = @import("codec/scanner.zig").Scanner;
const GenericReader = std.io.GenericReader;

const trace = @import("tracing.zig").scoped(.codec);

const util = @import("codec/util.zig");

//  ____                      _       _ _
// |  _ \  ___  ___  ___ _ __(_) __ _| (_)_______
// | | | |/ _ \/ __|/ _ \ '__| |/ _` | | |_  / _ \
// | |_| |  __/\__ \  __/ |  | | (_| | | |/ /  __/
// |____/ \___||___/\___|_|  |_|\__,_|_|_/___\___|

pub fn Deserialized(T: anytype) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
            self.* = undefined;
        }
    };
}

pub fn deserialize(
    comptime T: type,
    comptime params: anytype,
    parent_allocator: std.mem.Allocator,
    data: []const u8,
) !Deserialized(T) {
    const span = trace.span(.deserialize);
    defer span.deinit();
    span.debug("Starting deserialization for type {s}", .{@typeName(T)});
    span.trace("Input data length: {d} bytes", .{data.len});

    var result = Deserialized(T){
        .arena = try parent_allocator.create(ArenaAllocator),
        .value = undefined,
    };
    errdefer {
        span.debug("Cleanup after error - destroying arena", .{});
        parent_allocator.destroy(result.arena);
    }

    result.arena.* = ArenaAllocator.init(parent_allocator);
    errdefer {
        span.debug("Cleanup after error - deinitializing arena", .{});
        result.arena.deinit();
    }

    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    result.value = try recursiveDeserializeLeaky(T, params, result.arena.allocator(), reader);

    span.debug("Successfully deserialized type {s}", .{@typeName(T)});
    return result;
}

pub fn deserializeAlloc(
    comptime T: type,
    comptime params: anytype,
    allocator: std.mem.Allocator,
    reader: anytype,
) !T {
    const span = trace.span(.deserialize_alloc);
    defer span.deinit();
    span.debug("Starting allocation-based deserialization for type {s}", .{@typeName(T)});

    const result = try recursiveDeserializeLeaky(T, params, allocator, reader);
    span.debug("Successfully deserialized type {s} with allocator", .{@typeName(T)});
    return result;
}

/// (272) Function to decode an integer (0 to 2^64) from a variable-length
/// encoding as described in the gray paper.
pub fn readInteger(reader: anytype) !u64 {
    const span = trace.span(.read_integer);
    defer span.deinit();
    span.debug("Reading variable-length integer", .{});

    // Read first byte
    const first_byte = try reader.readByte();
    span.trace("First byte: 0x{X:0>2}", .{first_byte});

    if (first_byte == 0) {
        span.debug("Zero value detected", .{});
        return 0;
    }

    if (first_byte < 0x80) {
        span.debug("Single byte value: {d}", .{first_byte});
        return first_byte;
    }

    if (first_byte == 0xff) {
        span.debug("8-byte fixed-length integer detected", .{});
        var buf: [8]u8 = undefined;
        try reader.readNoEof(&buf);
        const value = decoder.decodeFixedLengthInteger(u64, &buf);
        span.debug("Decoded 8-byte value: {d}", .{value});
        span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(&buf)});
        return value;
    }

    const dl = util.decode_prefix(first_byte);
    span.trace("Decoded prefix - l: {d}, integer_multiple: {d}", .{ dl.l, dl.integer_multiple });

    var buf: [8]u8 = undefined;
    try reader.readNoEof(buf[0..dl.l]);
    const remainder = decoder.decodeFixedLengthInteger(u64, buf[0..dl.l]);
    const final_value = remainder + dl.integer_multiple;

    span.debug("Decoded variable-length integer: {d}", .{final_value});
    span.trace("Breakdown - remainder: {d}, multiple: {d}", .{ remainder, dl.integer_multiple });

    return final_value;
}

fn recursiveDeserializeLeaky(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype) !T {
    const span = trace.span(.recursive_deserialize);
    defer span.deinit();

    span.debug("Start deserializing type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
        .bool => {
            const byte = try reader.readByte();
            span.debug("Deserialized boolean: {}", .{byte != 0});
            return byte != 0;
        },
        .int => |intInfo| {
            span.debug("Deserializing {d}-bit integer", .{intInfo.bits});
            inline for (.{ u8, u16, u32, u64, u128 }) |t| {
                if (intInfo.bits == @bitSizeOf(t)) {
                    const buf = try reader.readBytesNoEof(intInfo.bits / 8);
                    const integer = decoder.decodeFixedLengthInteger(t, &buf);
                    span.debug("Decoded {d}-bit integer: {d}", .{ intInfo.bits, integer });
                    span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(&buf)});
                    return integer;
                }
            }
            span.err("Unhandled integer type: {d} bits", .{intInfo.bits});
            @panic("unhandled integer type");
        },
        .optional => |optionalInfo| {
            const present = try reader.readByte();
            span.debug("Deserializing optional, present byte: {d}", .{present});

            if (present == 0) {
                span.debug("Optional value is null", .{});
                return null;
            } else if (present == 1) {
                const child_span = span.child(.optional_value);
                defer child_span.deinit();
                child_span.debug("Deserializing optional child of type {s}", .{@typeName(optionalInfo.child)});
                const value = try recursiveDeserializeLeaky(optionalInfo.child, params, allocator, reader);
                child_span.debug("Successfully deserialized optional value", .{});
                return value;
            } else {
                span.err("Invalid present byte for optional: {d}", .{present});
                return error.InvalidValueForOptional;
            }
        },
        .float => {
            span.err("Float deserialization not implemented", .{});
            @compileError("Float deserialization not implemented yet");
        },
        .@"enum" => |enumInfo| {
            const enum_span = span.child(.enum_deserialize);
            defer enum_span.deinit();
            enum_span.debug("Deserializing enum type: {s}", .{@typeName(T)});

            const tag_value = try readInteger(reader);
            enum_span.debug("Read enum tag value: {d}", .{tag_value});

            if (tag_value >= enumInfo.fields.len) {
                enum_span.err("Invalid enum tag value: {d}", .{tag_value});
                return error.InvalidEnumTag;
            }

            return @enumFromInt(tag_value);
        },
        .@"struct" => |structInfo| {
            const struct_span = span.child(.struct_deserialize);
            defer struct_span.deinit();

            if (@hasDecl(T, "decode")) {
                struct_span.debug("Deserializing using custom decode method", .{});
                return try @call(.auto, @field(T, "decode"), .{
                    params,
                    reader,
                    allocator,
                });
            }

            struct_span.debug("Deserializing struct with {d} fields", .{structInfo.fields.len});

            var result: T = undefined;
            inline for (structInfo.fields) |field| {
                const field_span = struct_span.child(.field);
                defer field_span.deinit();
                field_span.debug("Deserializing field: {s} of type {s}", .{ field.name, @typeName(field.type) });

                const field_type = field.type;
                if (@hasDecl(T, field.name ++ "_size")) {
                    field_span.debug("Field has size function", .{});
                    const size_fn = @field(T, field.name ++ "_size");
                    const size = @call(.auto, size_fn, .{params});
                    field_span.debug("Size function returned: {d}", .{size});

                    const slice = try allocator.alloc(std.meta.Child(field_type), size);
                    field_span.trace("Allocated slice of size {d}", .{size});

                    for (slice, 0..) |*item, i| {
                        const item_span = field_span.child(.slice_item);
                        defer item_span.deinit();
                        item_span.debug("Deserializing item {d} of {d}", .{ i + 1, size });
                        item.* = try recursiveDeserializeLeaky(std.meta.Child(field_type), params, allocator, reader);
                    }
                    @field(result, field.name) = slice;
                } else {
                    const field_value = try recursiveDeserializeLeaky(field_type, params, allocator, reader);
                    @field(result, field.name) = field_value;
                }
                field_span.debug("Successfully deserialized field: {s}", .{field.name});
            }
            struct_span.debug("Successfully deserialized complete struct", .{});
            return result;
        },
        .array => |arrayInfo| {
            const array_span = span.child(.array);
            defer array_span.deinit();
            array_span.debug("Deserializing array of type {s}[{d}]", .{ @typeName(arrayInfo.child), arrayInfo.len });

            if (arrayInfo.sentinel_ptr != null) {
                array_span.err("Arrays with sentinels are not supported", .{});
                @compileError("Arrays with sentinels are not supported for deserialization");
            }
            return try deserializeArray(arrayInfo.child, arrayInfo.len, params, allocator, reader);
        },
        .pointer => |pointerInfo| {
            const ptr_span = span.child(.pointer);
            defer ptr_span.deinit();
            ptr_span.debug("Deserializing pointer type: {s}", .{@tagName(pointerInfo.size)});

            switch (pointerInfo.size) {
                .slice => {
                    const len = try readInteger(reader);
                    ptr_span.debug("Deserializing slice of length: {d}", .{len});

                    const slice = try allocator.alloc(pointerInfo.child, @intCast(len));
                    ptr_span.trace("Allocated slice of size {d}", .{len});

                    for (slice, 0..) |*item, i| {
                        const item_span = ptr_span.child(.slice_item);
                        defer item_span.deinit();
                        item_span.debug("Deserializing item {d} of {d}", .{ i + 1, len });
                        item.* = try recursiveDeserializeLeaky(pointerInfo.child, params, allocator, reader);
                    }
                    return slice;
                },
                .one, .many, .c => {
                    ptr_span.err("Unsupported pointer size: {s}", .{@tagName(pointerInfo.size)});
                    @compileError("Unsupported pointer type for deserialization: " ++ @typeName(T));
                },
            }
        },
        .@"union" => |unionInfo| {
            const union_span = span.child(.union_deserialize);
            defer union_span.deinit();
            union_span.debug("Deserializing union type: {s}", .{@typeName(T)});

            if (@hasDecl(T, "decode")) {
                union_span.debug("Using custom decode method", .{});
                return try @call(.auto, @field(T, "decode"), .{
                    params,
                    reader,
                    allocator,
                });
            }

            const tag_value = try readInteger(reader);
            union_span.debug("Read union tag value: {d}", .{tag_value});

            inline for (unionInfo.fields, 0..) |field, idx| {
                if (tag_value == idx) {
                    const field_span = union_span.child(.field);
                    defer field_span.deinit();
                    field_span.debug("Processing union field: {s}", .{field.name});

                    if (field.type == void) {
                        field_span.debug("Void field, no additional data to read", .{});
                        return @unionInit(T, field.name, {});
                    } else {
                        field_span.debug("Deserializing field value of type: {s}", .{@typeName(field.type)});

                        const field_type = field.type;
                        if (@hasDecl(T, field.name ++ "_size")) {
                            field_span.debug("Field has size function", .{});
                            const size_fn = @field(T, field.name ++ "_size");
                            const size = @call(.auto, size_fn, .{params});
                            field_span.debug("Size function returned: {d}", .{size});

                            const slice = try allocator.alloc(std.meta.Child(field_type), size);
                            field_span.trace("Allocated slice of size {d}", .{size});

                            for (slice, 0..) |*item, i| {
                                const item_span = field_span.child(.slice_item);
                                defer item_span.deinit();
                                item_span.debug("Deserializing item {d} of {d}", .{ i + 1, size });
                                item.* = try recursiveDeserializeLeaky(std.meta.Child(field_type), params, allocator, reader);
                            }
                            return @unionInit(T, field.name, slice);
                        }

                        const field_value = try recursiveDeserializeLeaky(field.type, params, allocator, reader);
                        return @unionInit(T, field.name, field_value);
                    }
                }
            }

            union_span.err("Invalid union tag: {d}", .{tag_value});
            return error.InvalidUnionTag;
        },
        else => {
            span.err("Unsupported type: {s}", .{@typeName(T)});
            @compileError("Unsupported type for deserialization: " ++ @typeName(T));
        },
    }
}

fn deserializeArray(comptime T: type, comptime len: usize, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype) ![len]T {
    const span = trace.span(.array_deserialize);
    defer span.deinit();
    span.debug("Deserializing fixed array - type: {s}, length: {d}", .{ @typeName(T), len });

    var result: [len]T = undefined;

    if (T == u8) {
        span.debug("Optimized path for byte array", .{});
        const bytes_read = try reader.readAll(&result);
        if (bytes_read != len) {
            span.err("Incomplete read - expected {d} bytes, got {d}", .{ len, bytes_read });
            return error.EndOfStream;
        }
        span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(&result)});
    } else {
        span.debug("Deserializing array elements individually", .{});
        for (&result, 0..) |*element, i| {
            const element_span = span.child(.array_element);
            defer element_span.deinit();
            element_span.debug("Deserializing element {d} of {d}", .{ i + 1, len });
            element.* = try recursiveDeserializeLeaky(T, params, allocator, reader);
        }
    }

    span.debug("Successfully deserialized complete array", .{});
    return result;
}

//  ____            _       _ _
// / ___|  ___ _ __(_) __ _| (_)_______
// \___ \ / _ \ '__| |/ _` | | |_  / _ \
//  ___) |  __/ |  | | (_| | | |/ /  __/
// |____/ \___|_|  |_|\__,_|_|_/___\___|

pub fn serialize(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const span = trace.span(.serialize);
    defer span.deinit();
    span.debug("Starting serialization of type {s}", .{@typeName(T)});
    try recursiveSerializeLeaky(T, params, writer, value);
    span.debug("Successfully completed serialization", .{});
}

pub fn serializeAlloc(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, value: T) ![]u8 {
    const span = trace.span(.serialize_alloc);
    defer span.deinit();
    span.debug("Starting allocation-based serialization for type {s}", .{@typeName(T)});

    var list = std.ArrayList(u8).init(allocator);
    errdefer {
        span.debug("Cleanup after error - deinitializing ArrayList", .{});
        list.deinit();
    }

    try recursiveSerializeLeaky(T, params, list.writer(), value);

    const result = try list.toOwnedSlice();
    span.debug("Successfully serialized {d} bytes", .{result.len});
    span.trace("Raw output: {any}", .{std.fmt.fmtSliceHexLower(result)});
    return result;
}

pub fn writeInteger(value: u64, writer: anytype) !void {
    const span = trace.span(.write_integer);
    defer span.deinit();
    span.debug("Writing integer value: {d}", .{value});

    const encoded = encoder.encodeInteger(value);
    span.trace("Encoded to {d} bytes: {any}", .{ encoded.len, std.fmt.fmtSliceHexLower(encoded.as_slice()) });

    try writer.writeAll(encoded.as_slice());
    span.debug("Successfully wrote encoded integer", .{});
}

pub fn recursiveSerializeLeaky(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const span = trace.span(.recursive_serialize);
    defer span.deinit();
    span.debug("Serializing type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
        .bool => {
            span.debug("Serializing boolean: {}", .{value});
            try writer.writeByte(if (value) 1 else 0);
        },
        .int => |intInfo| {
            span.debug("Serializing {d}-bit integer: {d}", .{ intInfo.bits, value });
            inline for (.{ u8, u16, u32, u64, u128 }) |t| {
                if (intInfo.bits == @bitSizeOf(t)) {
                    var buffer: [intInfo.bits / 8]u8 = undefined;
                    std.mem.writeInt(t, &buffer, value, .little);
                    span.trace("Encoded bytes: {any}", .{std.fmt.fmtSliceHexLower(&buffer)});
                    try writer.writeAll(&buffer);
                    return;
                }
            }
            span.err("Unhandled integer type: {d} bits", .{intInfo.bits});
            @panic("unhandled integer type");
        },
        .optional => |optionalInfo| {
            const opt_span = span.child(.optional);
            defer opt_span.deinit();
            opt_span.debug("Serializing optional of type {s}", .{@typeName(optionalInfo.child)});

            if (value) |v| {
                try writer.writeByte(1);
                opt_span.debug("Optional has value, serializing child", .{});
                try recursiveSerializeLeaky(optionalInfo.child, params, writer, v);
            } else {
                try writer.writeByte(0);
                opt_span.debug("Optional is null", .{});
            }
        },
        .float => {
            span.err("Float serialization not implemented", .{});
            @compileError("Float serialization not implemented yet");
        },
        .@"enum" => |_| {
            const enum_span = span.child(.enum_serialize);
            defer enum_span.deinit();
            enum_span.debug("Serializing enum value: {s}", .{@tagName(value)});

            const tag_value = @intFromEnum(value);
            try writeInteger(tag_value, writer);
            enum_span.debug("Wrote enum tag value: {d}", .{tag_value});
        },
        .@"struct" => |structInfo| {
            const struct_span = span.child(.struct_serialize);
            defer struct_span.deinit();
            struct_span.debug("Serializing struct with {d} fields", .{structInfo.fields.len});

            inline for (structInfo.fields) |field| {
                const field_span = struct_span.child(.field);
                defer field_span.deinit();
                field_span.debug("Serializing field: {s} of type {s}", .{ field.name, @typeName(field.type) });

                const field_value = @field(value, field.name);
                const field_type = field.type;

                if (@hasDecl(T, field.name ++ "_size")) {
                    field_span.debug("Field has size function", .{});
                    const size_fn = @field(T, field.name ++ "_size");
                    const size = @call(.auto, size_fn, .{params});
                    field_span.debug("Size function returned: {d}", .{size});

                    for (field_value[0..size], 0..) |item, i| {
                        const item_span = field_span.child(.slice_item);
                        defer item_span.deinit();
                        item_span.debug("Serializing item {d} of {d}", .{ i + 1, size });
                        try recursiveSerializeLeaky(std.meta.Child(field_type), params, writer, item);
                    }
                } else {
                    try recursiveSerializeLeaky(field_type, params, writer, field_value);
                }
                field_span.debug("Successfully serialized field: {s}", .{field.name});
            }
            struct_span.debug("Successfully serialized complete struct", .{});
        },
        .array => |arrayInfo| {
            if (arrayInfo.sentinel_ptr != null) {
                span.err("Arrays with sentinels are not supported", .{});
                @compileError("Arrays with sentinels are not supported for serialization");
            }
            try serializeArray(arrayInfo.child, arrayInfo.len, writer, value);
        },
        .pointer => |pointerInfo| {
            const ptr_span = span.child(.pointer);
            defer ptr_span.deinit();
            ptr_span.debug("Serializing pointer type: {s}", .{@tagName(pointerInfo.size)});

            switch (pointerInfo.size) {
                .slice => {
                    ptr_span.debug("Serializing slice of length: {d}", .{value.len});
                    try writeInteger(value.len, writer);

                    for (value, 0..) |item, i| {
                        const item_span = ptr_span.child(.slice_item);
                        defer item_span.deinit();
                        item_span.debug("Serializing item {d} of {d}", .{ i + 1, value.len });
                        try recursiveSerializeLeaky(pointerInfo.child, params, writer, item);
                    }
                },
                .one, .many, .c => {
                    ptr_span.err("Unsupported pointer size: {s}", .{@tagName(pointerInfo.size)});
                    @compileError("Unsupported pointer type for serialization: " ++ @typeName(T));
                },
            }
        },
        .@"union" => |unionInfo| {
            const union_span = span.child(.union_serialize);
            defer union_span.deinit();
            union_span.debug("Serializing union type: {s}", .{@typeName(T)});

            if (@hasDecl(T, "encode")) {
                union_span.debug("Using custom encode method", .{});
                return try @call(.auto, @field(T, "encode"), .{ &value, params, writer });
            }

            const tag = std.meta.activeTag(value);
            const tag_value = @intFromEnum(tag);
            union_span.debug("Union tag: {s} (value: {d})", .{ @tagName(tag), tag_value });

            try writer.writeAll(encoder.encodeInteger(tag_value).as_slice());

            inline for (unionInfo.fields) |field| {
                if (std.mem.eql(u8, @tagName(tag), field.name)) {
                    const field_span = union_span.child(.field);
                    defer field_span.deinit();
                    field_span.debug("Processing union field: {s}", .{field.name});

                    if (field.type == void) {
                        field_span.debug("Void field, no additional data to write", .{});
                    } else {
                        const field_value = @field(value, field.name);
                        const field_type = field.type;
                        if (@hasDecl(T, field.name ++ "_size")) {
                            field_span.debug("Field has size function", .{});
                            const size_fn = @field(T, field.name ++ "_size");
                            const size = @call(.auto, size_fn, .{params});
                            field_span.debug("Size function returned: {d}", .{size});

                            if (field_value.len != size) {
                                field_span.err("Field slice length {d} does not match size function return value {d}", .{ field_value.len, size });
                                return error.InvalidSliceLength;
                            }

                            for (field_value[0..size], 0..) |item, i| {
                                const item_span = field_span.child(.slice_item);
                                defer item_span.deinit();
                                item_span.debug("Serializing item {d} of {d}", .{ i + 1, size });
                                try recursiveSerializeLeaky(std.meta.Child(field_type), params, writer, item);
                            }
                            return;
                        }

                        field_span.debug("Serializing field value of type: {s}", .{@typeName(field.type)});
                        try recursiveSerializeLeaky(field.type, params, writer, field_value);
                    }
                    break;
                }
            }
            union_span.debug("Successfully serialized union", .{});
        },
        else => {
            span.err("Unsupported type: {s}", .{@typeName(T)});
            @compileError("Unsupported type for serialization: " ++ @typeName(T));
        },
    }
}

pub fn serializeArray(comptime T: type, comptime len: usize, writer: anytype, value: [len]T) !void {
    const span = trace.span(.array_serialize);
    defer span.deinit();
    span.debug("Serializing array - type: {s}, length: {d}", .{ @typeName(T), len });

    const bytes = std.mem.asBytes(&value);
    span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(bytes)});
    try writer.writeAll(bytes);
    span.debug("Successfully wrote array bytes", .{});
}

/// Serializes a slice as an array without adding a length prefix to the output.
/// This function is useful when you need to serialize a slice of known length
/// or when the length information is stored separately.
///
/// Note: This differs from the standard slice serialization, which typically
/// includes a length prefix. Use this function only when you're certain that
/// the receiver knows the expected length of the data.
pub fn serializeSliceAsArray(comptime T: type, writer: anytype, value: []const T) !void {
    const span = trace.span(.serialize_slice_as_array);
    defer span.deinit();
    span.debug("Serializing slice as array - type: {s}, length: {d}", .{ @typeName(T), value.len });

    for (value, 0..) |item, i| {
        const item_span = span.child(.slice_item);
        defer item_span.deinit();
        item_span.debug("Serializing item {d} of {d}", .{ i + 1, value.len });
        try recursiveSerializeLeaky(T, .{}, writer, item);
    }
    span.debug("Successfully serialized all items", .{});
}

// Tests
comptime {
    _ = @import("codec/tests.zig");
    _ = @import("codec/encoder/tests.zig");
    _ = @import("codec/decoder/tests.zig");
    _ = @import("codec/encoder.zig");
}
