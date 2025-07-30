const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
pub const decoder = @import("codec/decoder.zig");
pub const encoder = @import("codec/encoder.zig");
const Scanner = @import("codec/scanner.zig").Scanner;
const GenericReader = std.io.GenericReader;
pub const DecodingContext = @import("codec/context.zig").DecodingContext;

const trace = @import("tracing.zig").scoped(.codec);

// Tests
comptime {
    _ = @import("codec/tests.zig");
    _ = @import("codec/encoder/tests.zig");
    _ = @import("codec/decoder/tests.zig");
    _ = @import("codec/encoder.zig");
}

const util = @import("codec/util.zig");

// ---- Error Sets ----

/// Errors that can occur during deserialization
pub const DeserializationError = error{
    /// Invalid enum tag value encountered
    InvalidEnumTagValue,
    /// Invalid union tag value encountered
    InvalidUnionTagValue,
    /// Invalid byte value for optional (must be 0 or 1)
    InvalidOptionalByte,
    /// Unexpected end of stream while reading
    UnexpectedEndOfStream,
    /// Union field slice length doesn't match size function
    InvalidSliceLengthMismatch,
};

// ---- Constants ----

/// Maximum value that can be encoded in a single byte
const SINGLE_BYTE_MAX = 0x80;
/// Marker byte indicating 8-byte fixed-length integer follows
const EIGHT_BYTE_MARKER = 0xff;

// ---- Context Types ----

/// Generic deserialization context type - use DeserializationContext() to create
pub fn DeserializationContext(comptime Params: type, comptime Reader: type) type {
    return struct {
        params: Params,
        allocator: std.mem.Allocator,
        reader: Reader,
    };
}

/// Generic serialization context type - use SerializationContext() to create
pub fn SerializationContext(comptime Params: type, comptime Writer: type) type {
    return struct {
        params: Params,
        writer: Writer,
    };
}

// ---- Deserialization ----

/// Wrapper type for deserialized values that manages arena allocation cleanup
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

/// Deserializes a value of type T from a reader, returning a Deserialized wrapper
/// that manages memory cleanup. The wrapper must be deinitialized after use.
///
/// Parameters:
/// - T: The type to deserialize
/// - params: Compile-time parameters passed to custom decode methods
/// - parent_allocator: The allocator to use for creating the arena
/// - reader: Any reader that supports readByte, readAll, readNoEof operations
pub fn deserialize(
    comptime T: type,
    comptime params: anytype,
    parent_allocator: std.mem.Allocator,
    reader: anytype,
) !Deserialized(T) {
    const span = trace.span(.deserialize);
    defer span.deinit();
    span.debug("Starting deserialization for type {s}", .{@typeName(T)});

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

    result.value = try deserializeInternal(T, params, result.arena.allocator(), reader, null);

    span.debug("Successfully deserialized type {s}", .{@typeName(T)});
    return result;
}

/// Deserializes a value of type T from a reader, using the provided allocator directly.
/// Unlike deserialize(), this returns the value directly without a wrapper.
/// Memory is tracked and will be freed on error, but must be managed by caller on success.
///
/// Parameters:
/// - T: The type to deserialize
/// - params: Compile-time parameters passed to custom decode methods
/// - allocator: The allocator to use for any allocations
/// - reader: Any reader that supports readByte, readAll, readNoEof operations
pub fn deserializeAlloc(
    comptime T: type,
    comptime params: anytype,
    allocator: std.mem.Allocator,
    reader: anytype,
) !T {
    const span = trace.span(.deserialize_alloc);
    defer span.deinit();
    span.debug("Starting allocation-based deserialization for type {s}", .{@typeName(T)});

    const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;
    var tracking_allocator = TrackingAllocator.init(allocator);
    defer tracking_allocator.deinit();

    const result = deserializeInternal(T, params, tracking_allocator.allocator(), reader, null) catch |err| {
        const inner_span = span.child(.cleanup_on_error);
        defer inner_span.deinit();
        inner_span.debug("Deserialization failed, cleaning up {d} tracked allocations", .{tracking_allocator.allocations.items.len});
        tracking_allocator.freeAllAllocations();
        return err;
    };

    // Success - commit allocations to prevent cleanup
    tracking_allocator.commitAllocations();
    span.debug("Successfully deserialized type {s} with allocator", .{@typeName(T)});
    return result;
}

/// Deserializes a value of type T from a reader with context tracking, returning a Deserialized wrapper
/// that manages memory cleanup. The wrapper must be deinitialized after use.
/// The context provides detailed error information including the exact path where deserialization failed.
///
/// Parameters:
/// - T: The type to deserialize
/// - params: Compile-time parameters passed to custom decode methods
/// - parent_allocator: The allocator to use for creating the arena
/// - reader: Any reader that supports readByte, readAll, readNoEof operations
/// - context: DecodingContext for tracking decoding path and errors
pub fn deserializeWithContext(
    comptime T: type,
    comptime params: anytype,
    parent_allocator: std.mem.Allocator,
    reader: anytype,
    context: *DecodingContext,
) !Deserialized(T) {
    const span = trace.span(.deserialize_with_context);
    defer span.deinit();
    span.debug("Starting deserialization with context for type {s}", .{@typeName(T)});

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

    result.value = try deserializeInternal(T, params, result.arena.allocator(), reader, context);

    span.debug("Successfully deserialized type {s} with context", .{@typeName(T)});
    return result;
}

/// Deserializes a value of type T from a reader with context tracking, using the provided allocator directly.
/// Unlike deserializeWithContext(), this returns the value directly without a wrapper.
/// Memory is tracked and will be freed on error, but must be managed by caller on success.
/// The context provides detailed error information including the exact path where deserialization failed.
///
/// Parameters:
/// - T: The type to deserialize
/// - params: Compile-time parameters passed to custom decode methods
/// - allocator: The allocator to use for any allocations
/// - reader: Any reader that supports readByte, readAll, readNoEof operations
/// - context: DecodingContext for tracking decoding path and errors
pub fn deserializeAllocWithContext(
    comptime T: type,
    comptime params: anytype,
    allocator: std.mem.Allocator,
    reader: anytype,
    context: *DecodingContext,
) !T {
    const span = trace.span(.deserialize_alloc_with_context);
    defer span.deinit();
    span.debug("Starting allocation-based deserialization with context for type {s}", .{@typeName(T)});

    const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;
    var tracking_allocator = TrackingAllocator.init(allocator);
    defer tracking_allocator.deinit();

    const result = deserializeInternal(T, params, tracking_allocator.allocator(), reader, context) catch |err| {
        const inner_span = span.child(.cleanup_on_error);
        defer inner_span.deinit();
        inner_span.debug("Deserialization failed, cleaning up {d} tracked allocations", .{tracking_allocator.allocations.items.len});
        tracking_allocator.freeAllAllocations();
        return err;
    };

    // Success - commit allocations to prevent cleanup
    tracking_allocator.commitAllocations();
    span.debug("Successfully deserialized type {s} with allocator and context", .{@typeName(T)});
    return result;
}

/// (272) Function to decode an integer (0 to 2^64) from a variable-length
/// encoding as described in the gray paper.
pub fn readInteger(reader: anytype) !u64 {
    return readIntegerWithContext(reader, null);
}

/// (272) Function to decode an integer (0 to 2^64) from a variable-length
/// encoding as described in the gray paper, with optional context tracking.
pub fn readIntegerWithContext(reader: anytype, context: ?*DecodingContext) !u64 {
    const span = trace.span(.read_integer);
    defer span.deinit();
    span.debug("Reading variable-length integer", .{});

    // Read first byte
    const first_byte = reader.readByte() catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "failed to read first byte of integer: {s}", .{@errorName(err)});
        }
        return err;
    };
    if (context) |ctx| ctx.addOffset(1);
    span.trace("First byte: 0x{X:0>2}", .{first_byte});

    if (first_byte == 0) {
        span.debug("Zero value detected", .{});
        return 0;
    }

    if (first_byte < SINGLE_BYTE_MAX) {
        span.debug("Single byte value: {d}", .{first_byte});
        return first_byte;
    }

    if (first_byte == EIGHT_BYTE_MARKER) {
        span.debug("8-byte fixed-length integer detected", .{});
        var buf: [8]u8 = undefined;
        reader.readNoEof(&buf) catch |err| {
            if (context) |ctx| {
                return ctx.makeError(err, "failed to read 8-byte integer: {s}", .{@errorName(err)});
            }
            return err;
        };
        if (context) |ctx| ctx.addOffset(8);
        const value = decoder.decodeFixedLengthInteger(u64, &buf);
        span.debug("Decoded 8-byte value: {d}", .{value});
        span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(&buf)});
        return value;
    }

    const dl = util.decodePrefixByte(first_byte) catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "invalid prefix byte: 0x{X:0>2}", .{first_byte});
        }
        return err;
    };
    span.trace("Decoded prefix - l: {d}, integer_multiple: {d}", .{ dl.l, dl.integer_multiple });

    var buf: [8]u8 = undefined;
    reader.readNoEof(buf[0..dl.l]) catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "failed to read {d} bytes of variable-length integer: {s}", .{ dl.l, @errorName(err) });
        }
        return err;
    };
    if (context) |ctx| ctx.addOffset(dl.l);
    const remainder = decoder.decodeFixedLengthInteger(u64, buf[0..dl.l]);
    const final_value = remainder + dl.integer_multiple;

    span.debug("Decoded variable-length integer: {d}", .{final_value});
    span.trace("Breakdown - remainder: {d}, multiple: {d}", .{ remainder, dl.integer_multiple });

    return final_value;
}

// ---- Common Helper Functions ----

/// Helper function to deserialize a sized field (used by structs and unions)
fn deserializeSizedField(
    comptime ParentType: type,
    comptime field_name: []const u8,
    comptime FieldType: type,
    comptime params: anytype,
    allocator: std.mem.Allocator,
    reader: anytype,
    context: ?*DecodingContext,
) ![]std.meta.Child(FieldType) {
    const span = trace.span(.deserialize_sized_field);
    defer span.deinit();

    span.debug("Field has size function", .{});
    const size_fn = @field(ParentType, field_name ++ "_size");
    const size = @call(.auto, size_fn, .{params});
    span.debug("Size function returned: {d}", .{size});

    const slice = try allocator.alloc(std.meta.Child(FieldType), size);
    span.trace("Allocated slice of size {d}", .{size});

    for (slice, 0..) |*item, i| {
        if (context) |ctx| {
            try ctx.push(.{ .slice_item = i });
        }
        defer if (context) |ctx| ctx.pop();

        const item_span = span.child(.slice_item);
        defer item_span.deinit();
        item_span.debug("Deserializing item {d} of {d}", .{ i + 1, size });
        item.* = try deserializeInternal(std.meta.Child(FieldType), params, allocator, reader, context);
    }

    return slice;
}

/// Helper function to serialize a sized field (used by structs and unions)
fn serializeSizedField(
    comptime ParentType: type,
    comptime field_name: []const u8,
    comptime FieldType: type,
    comptime params: anytype,
    writer: anytype,
    field_value: []const std.meta.Child(FieldType),
) !void {
    const span = trace.span(.serialize_sized_field);
    defer span.deinit();

    span.debug("Field has size function", .{});
    const size_fn = @field(ParentType, field_name ++ "_size");
    const size = @call(.auto, size_fn, .{params});
    span.debug("Size function returned: {d}", .{size});

    if (field_value.len != size) {
        span.err("Field slice length {d} does not match size function return value {d}", .{ field_value.len, size });
        return DeserializationError.InvalidSliceLengthMismatch;
    }

    for (field_value[0..size], 0..) |item, i| {
        const item_span = span.child(.slice_item);
        defer item_span.deinit();
        item_span.debug("Serializing item {d} of {d}", .{ i + 1, size });
        try serializeInternal(std.meta.Child(FieldType), params, writer, item);
    }
}

// ---- Type-specific Deserialization Functions ----

fn deserializeBool(reader: anytype, context: ?*DecodingContext) !bool {
    const byte = reader.readByte() catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "failed to read bool: {s}", .{@errorName(err)});
        }
        return err;
    };
    if (context) |ctx| ctx.addOffset(1);
    return byte != 0;
}

fn deserializeInt(comptime T: type, reader: anytype, context: ?*DecodingContext) !T {
    const intInfo = @typeInfo(T).int;
    const span = trace.span(.deserialize_int);
    defer span.deinit();

    span.debug("Deserializing {d}-bit integer", .{intInfo.bits});
    inline for (.{ u8, u16, u32, u64, u128 }) |t| {
        if (intInfo.bits == @bitSizeOf(t)) {
            const buf = reader.readBytesNoEof(intInfo.bits / 8) catch |err| {
                if (context) |ctx| {
                    return ctx.makeError(err, "failed to read {d}-bit integer: {s}", .{ intInfo.bits, @errorName(err) });
                }
                return err;
            };
            if (context) |ctx| ctx.addOffset(intInfo.bits / 8);
            const integer = decoder.decodeFixedLengthInteger(t, &buf);
            span.debug("Decoded {d}-bit integer: {d}", .{ intInfo.bits, integer });
            span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(&buf)});
            return integer;
        }
    }
    span.err("Unhandled integer type: {d} bits", .{intInfo.bits});
    @panic("unhandled integer type");
}

fn deserializeOptional(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype, context: ?*DecodingContext) !T {
    const optionalInfo = @typeInfo(T).optional;
    const span = trace.span(.deserialize_optional);
    defer span.deinit();

    const present = reader.readByte() catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "failed to read optional present byte: {s}", .{@errorName(err)});
        }
        return err;
    };
    if (context) |ctx| ctx.addOffset(1);
    span.debug("Deserializing optional, present byte: {d}", .{present});

    if (present == 0) {
        span.debug("Optional value is null", .{});
        return null;
    } else if (present == 1) {
        const child_span = span.child(.optional_value);
        defer child_span.deinit();
        child_span.debug("Deserializing optional child of type {s}", .{@typeName(optionalInfo.child)});
        const value = try deserializeInternal(optionalInfo.child, params, allocator, reader, context);
        child_span.debug("Successfully deserialized optional value", .{});
        return value;
    } else {
        span.err("Invalid present byte for optional: {d}", .{present});
        const err = DeserializationError.InvalidOptionalByte;
        if (context) |ctx| {
            return ctx.makeError(err, "invalid optional present byte: {d} (must be 0 or 1)", .{present});
        }
        return err;
    }
}

fn deserializeEnum(comptime T: type, reader: anytype, context: ?*DecodingContext) !T {
    const enumInfo = @typeInfo(T).@"enum";
    const enum_span = trace.span(.enum_deserialize);
    defer enum_span.deinit();
    enum_span.debug("Deserializing enum type: {s}", .{@typeName(T)});

    const tag_value = readIntegerWithContext(reader, context) catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "failed to read enum tag: {s}", .{@errorName(err)});
        }
        return err;
    };
    enum_span.debug("Read enum tag value: {d}", .{tag_value});

    if (tag_value >= enumInfo.fields.len) {
        enum_span.err("Invalid enum tag value: {d}", .{tag_value});
        const err = DeserializationError.InvalidEnumTagValue;
        if (context) |ctx| {
            return ctx.makeError(err, "invalid enum tag {d} for type {s} (max: {d})", .{ tag_value, @typeName(T), enumInfo.fields.len - 1 });
        }
        return err;
    }

    return @enumFromInt(tag_value);
}

fn deserializeStruct(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype, context: ?*DecodingContext) !T {
    const structInfo = @typeInfo(T).@"struct";
    const struct_span = trace.span(.struct_deserialize);
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
        if (context) |ctx| {
            try ctx.push(.{ .field = field.name });
        }
        defer if (context) |ctx| ctx.pop();

        const field_span = struct_span.child(.field);
        defer field_span.deinit();
        field_span.debug("Deserializing field: {s} of type {s}", .{ field.name, @typeName(field.type) });

        const field_type = field.type;
        if (@hasDecl(T, field.name ++ "_size")) {
            @field(result, field.name) = try deserializeSizedField(T, field.name, field_type, params, allocator, reader, context);
        } else {
            const field_value = try deserializeInternal(field_type, params, allocator, reader, context);
            @field(result, field.name) = field_value;
        }
        field_span.debug("Successfully deserialized field: {s}", .{field.name});
    }
    struct_span.debug("Successfully deserialized complete struct", .{});
    return result;
}

fn deserializeUnion(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype, context: ?*DecodingContext) !T {
    const unionInfo = @typeInfo(T).@"union";
    const union_span = trace.span(.union_deserialize);
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

    const tag_value = readIntegerWithContext(reader, context) catch |err| {
        if (context) |ctx| {
            return ctx.makeError(err, "failed to read union tag: {s}", .{@errorName(err)});
        }
        return err;
    };
    union_span.debug("Read union tag value: {d}", .{tag_value});

    inline for (unionInfo.fields, 0..) |field, idx| {
        if (tag_value == idx) {
            if (context) |ctx| {
                try ctx.push(.{ .union_variant = field.name });
            }
            defer if (context) |ctx| ctx.pop();

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
                    const slice = try deserializeSizedField(T, field.name, field_type, params, allocator, reader, context);
                    return @unionInit(T, field.name, slice);
                }

                const field_value = try deserializeInternal(field.type, params, allocator, reader, context);
                return @unionInit(T, field.name, field_value);
            }
        }
    }

    union_span.err("Invalid union tag: {d}", .{tag_value});
    const err = DeserializationError.InvalidUnionTagValue;
    if (context) |ctx| {
        return ctx.makeError(err, "invalid union tag {d} for type {s} (max: {d})", .{ tag_value, @typeName(T), unionInfo.fields.len - 1 });
    }
    return err;
}

fn deserializePointer(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype, context: ?*DecodingContext) !T {
    const pointerInfo = @typeInfo(T).pointer;
    const ptr_span = trace.span(.pointer);
    defer ptr_span.deinit();
    ptr_span.debug("Deserializing pointer type: {s}", .{@tagName(pointerInfo.size)});

    switch (pointerInfo.size) {
        .slice => {
            const len = readIntegerWithContext(reader, context) catch |err| {
                if (context) |ctx| {
                    return ctx.makeError(err, "failed to read slice length: {s}", .{@errorName(err)});
                }
                return err;
            };
            ptr_span.debug("Deserializing slice of length: {d}", .{len});

            const slice = try allocator.alloc(pointerInfo.child, @intCast(len));
            ptr_span.trace("Allocated slice of size {d}", .{len});

            if (pointerInfo.child == u8) {
                ptr_span.debug("Optimized path for byte array", .{});
                const bytes_read = reader.readAll(slice) catch |err| {
                    if (context) |ctx| {
                        return ctx.makeError(err, "failed to read byte slice: {s}", .{@errorName(err)});
                    }
                    return err;
                };
                if (bytes_read != len) {
                    ptr_span.err("Incomplete read - expected {d} bytes, got {d}", .{ len, bytes_read });
                    const err = DeserializationError.UnexpectedEndOfStream;
                    if (context) |ctx| {
                        return ctx.makeError(err, "incomplete read - expected {d} bytes, got {d}", .{ len, bytes_read });
                    }
                    return err;
                }
                if (context) |ctx| ctx.addOffset(bytes_read);
                ptr_span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(slice)});
            } else {
                for (slice, 0..) |*item, i| {
                    if (context) |ctx| {
                        try ctx.push(.{ .slice_item = i });
                    }
                    defer if (context) |ctx| ctx.pop();
                    const item_span = ptr_span.child(.slice_item);
                    defer item_span.deinit();
                    item_span.debug("Deserializing item {d} of {d}", .{ i + 1, len });
                    item.* = try deserializeInternal(pointerInfo.child, params, allocator, reader, context);
                }
            }
            return slice;
        },
        .one, .many, .c => {
            ptr_span.err("Unsupported pointer size: {s}", .{@tagName(pointerInfo.size)});
            @compileError("Unsupported pointer type for deserialization: " ++ @typeName(T));
        },
    }
}

fn deserializeInternal(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype, context: ?*DecodingContext) !T {
    const span = trace.span(.recursive_deserialize);
    defer span.deinit();

    span.debug("Start deserializing type: {s}", .{@typeName(T)});

    // Push type name to context if available
    if (context) |ctx| {
        try ctx.push(.{ .type_name = @typeName(T) });
    }
    defer if (context) |ctx| ctx.pop();

    switch (@typeInfo(T)) {
        .bool => return try deserializeBool(reader, context),
        .int => return try deserializeInt(T, reader, context),
        .optional => return try deserializeOptional(T, params, allocator, reader, context),
        .float => {
            span.err("Float deserialization not implemented", .{});
            @compileError("Float deserialization not implemented yet");
        },
        .@"enum" => return try deserializeEnum(T, reader, context),
        .@"struct" => return try deserializeStruct(T, params, allocator, reader, context),
        .array => |arrayInfo| {
            const array_span = span.child(.array);
            defer array_span.deinit();
            array_span.debug("Deserializing array of type {s}[{d}]", .{ @typeName(arrayInfo.child), arrayInfo.len });

            if (arrayInfo.sentinel_ptr != null) {
                array_span.err("Arrays with sentinels are not supported", .{});
                @compileError("Arrays with sentinels are not supported for deserialization");
            }
            return try deserializeArray(arrayInfo.child, arrayInfo.len, params, allocator, reader, context);
        },
        .pointer => return try deserializePointer(T, params, allocator, reader, context),
        .@"union" => return try deserializeUnion(T, params, allocator, reader, context),
        else => {
            span.err("Unsupported type: {s}", .{@typeName(T)});
            @compileError("Unsupported type for deserialization: " ++ @typeName(T));
        },
    }
}

fn deserializeArray(comptime T: type, comptime len: usize, comptime params: anytype, allocator: std.mem.Allocator, reader: anytype, context: ?*DecodingContext) ![len]T {
    const span = trace.span(.array_deserialize);
    defer span.deinit();
    span.debug("Deserializing fixed array - type: {s}, length: {d}", .{ @typeName(T), len });

    var result: [len]T = undefined;

    if (T == u8) {
        span.debug("Optimized path for byte array", .{});
        const bytes_read = reader.readAll(&result) catch |err| {
            if (context) |ctx| {
                return ctx.makeError(err, "failed to read byte array: {s}", .{@errorName(err)});
            }
            return err;
        };
        if (bytes_read != len) {
            span.err("Incomplete read - expected {d} bytes, got {d}", .{ len, bytes_read });
            const err = DeserializationError.UnexpectedEndOfStream;
            if (context) |ctx| {
                return ctx.makeError(err, "incomplete read - expected {d} bytes, got {d}", .{ len, bytes_read });
            }
            return err;
        }
        if (context) |ctx| ctx.addOffset(bytes_read);
        span.trace("Raw bytes: {any}", .{std.fmt.fmtSliceHexLower(&result)});
    } else {
        span.debug("Deserializing array elements individually", .{});
        for (&result, 0..) |*element, i| {
            if (context) |ctx| {
                try ctx.push(.{ .array_index = i });
            }
            defer if (context) |ctx| ctx.pop();
            const element_span = span.child(.array_element);
            defer element_span.deinit();
            element_span.debug("Deserializing element {d} of {d}", .{ i + 1, len });
            element.* = try deserializeInternal(T, params, allocator, reader, context);
        }
    }

    span.debug("Successfully deserialized complete array", .{});
    return result;
}

// ---- Serialization ----

/// Serializes a value to a writer using the JAM codec format.
///
/// Parameters:
/// - T: The type to serialize
/// - params: Compile-time parameters passed to custom encode methods
/// - writer: Any writer that supports writeByte and writeAll operations
/// - value: The value to serialize
pub fn serialize(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const span = trace.span(.serialize);
    defer span.deinit();
    span.debug("Starting serialization of type {s}", .{@typeName(T)});
    try serializeInternal(T, params, writer, value);
    span.debug("Successfully completed serialization", .{});
}

/// Serializes a value to a newly allocated byte slice.
///
/// Parameters:
/// - T: The type to serialize
/// - params: Compile-time parameters passed to custom encode methods
/// - allocator: The allocator to use for the result slice
/// - value: The value to serialize
///
/// Returns: An owned slice containing the serialized data
pub fn serializeAlloc(comptime T: type, comptime params: anytype, allocator: std.mem.Allocator, value: T) ![]u8 {
    const span = trace.span(.serialize_alloc);
    defer span.deinit();
    span.debug("Starting allocation-based serialization for type {s}", .{@typeName(T)});

    var list = std.ArrayList(u8).init(allocator);
    errdefer {
        span.debug("Cleanup after error - deinitializing ArrayList", .{});
        list.deinit();
    }

    try serializeInternal(T, params, list.writer(), value);

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

// ---- Type-specific Serialization Functions ----

fn serializeBool(writer: anytype, value: bool) !void {
    try writer.writeByte(if (value) 1 else 0);
}

fn serializeInt(comptime T: type, writer: anytype, value: T) !void {
    const intInfo = @typeInfo(T).int;
    const span = trace.span(.serialize_int);
    defer span.deinit();

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
}

fn serializeOptional(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const optionalInfo = @typeInfo(T).optional;
    const opt_span = trace.span(.optional);
    defer opt_span.deinit();
    opt_span.debug("Serializing optional of type {s}", .{@typeName(optionalInfo.child)});

    if (value) |v| {
        try writer.writeByte(1);
        opt_span.debug("Optional has value, serializing child", .{});
        try serializeInternal(optionalInfo.child, params, writer, v);
    } else {
        try writer.writeByte(0);
        opt_span.debug("Optional is null", .{});
    }
}

fn serializeEnum(comptime T: type, writer: anytype, value: T) !void {
    const enum_span = trace.span(.enum_serialize);
    defer enum_span.deinit();
    enum_span.debug("Serializing enum value: {s}", .{@tagName(value)});

    const tag_value = @intFromEnum(value);
    try writeInteger(tag_value, writer);
    enum_span.debug("Wrote enum tag value: {d}", .{tag_value});
}

fn serializeStruct(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const structInfo = @typeInfo(T).@"struct";
    const struct_span = trace.span(.struct_serialize);
    defer struct_span.deinit();

    if (@hasDecl(T, "encode")) {
        struct_span.debug("Encoding using custom encode method", .{});
        return try @call(.auto, @field(T, "encode"), .{
            &value,
            params,
            writer,
        });
    }

    struct_span.debug("Serializing struct with {d} fields", .{structInfo.fields.len});

    inline for (structInfo.fields) |field| {
        const field_span = struct_span.child(.field);
        defer field_span.deinit();
        field_span.debug("Serializing field: {s} of type {s}", .{ field.name, @typeName(field.type) });

        const field_value = @field(value, field.name);
        const field_type = field.type;

        if (@hasDecl(T, field.name ++ "_size")) {
            try serializeSizedField(T, field.name, field_type, params, writer, field_value);
        } else {
            try serializeInternal(field_type, params, writer, field_value);
        }
        field_span.debug("Successfully serialized field: {s}", .{field.name});
    }
    struct_span.debug("Successfully serialized complete struct", .{});
}

fn serializePointer(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const pointerInfo = @typeInfo(T).pointer;
    const ptr_span = trace.span(.pointer);
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
                try serializeInternal(pointerInfo.child, params, writer, item);
            }
        },
        .one, .many, .c => {
            ptr_span.err("Unsupported pointer size: {s}", .{@tagName(pointerInfo.size)});
            @compileError("Unsupported pointer type for serialization: " ++ @typeName(T));
        },
    }
}

fn serializeUnion(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const unionInfo = @typeInfo(T).@"union";
    const union_span = trace.span(.union_serialize);
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
                    try serializeSizedField(T, field.name, field_type, params, writer, field_value);
                    return;
                }

                field_span.debug("Serializing field value of type: {s}", .{@typeName(field.type)});
                try serializeInternal(field.type, params, writer, field_value);
            }
            break;
        }
    }
    union_span.debug("Successfully serialized union", .{});
}

pub fn serializeInternal(comptime T: type, comptime params: anytype, writer: anytype, value: T) !void {
    const span = trace.span(.recursive_serialize);
    defer span.deinit();
    span.debug("Serializing type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
        .bool => return try serializeBool(writer, value),
        .int => return try serializeInt(T, writer, value),
        .optional => return try serializeOptional(T, params, writer, value),
        .float => {
            span.err("Float serialization not implemented", .{});
            @compileError("Float serialization not implemented yet");
        },
        .@"enum" => return try serializeEnum(T, writer, value),
        .@"struct" => return try serializeStruct(T, params, writer, value),
        .array => |arrayInfo| {
            if (arrayInfo.sentinel_ptr != null) {
                span.err("Arrays with sentinels are not supported", .{});
                @compileError("Arrays with sentinels are not supported for serialization");
            }
            try serializeArray(arrayInfo.child, arrayInfo.len, writer, value);
        },
        .pointer => return try serializePointer(T, params, writer, value),
        .@"union" => return try serializeUnion(T, params, writer, value),
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
        try serializeInternal(T, .{}, writer, item);
    }
    span.debug("Successfully serialized all items", .{});
}
