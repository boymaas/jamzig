const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const decoder = @import("codec/decoder.zig");
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

pub fn deserialize(comptime T: type, parent_allocator: std.mem.Allocator, data: []u8) !Deserialized(T) {
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
    result.value = try recursiveDeserializeLeaky(T, result.arena.allocator(), &scanner);

    return result;
}

/// `scanner_or_reader` must be either a `*std.json.Scanner` with complete input or a `*std.json.Reader`.
/// Allocations made during this operation are not carefully tracked and may not be possible to individually clean up.
/// It is recommended to use a `std.heap.ArenaAllocator` or similar.
fn recursiveDeserializeLeaky(comptime T: type, allocator: std.mem.Allocator, scanner: *Scanner) !T {
    trace(@src(), "start - type: {s}", .{@typeName(T)});
    defer trace(@src(), "recursiveDeserializeLeaky: end - type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
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
                return try recursiveDeserializeLeaky(optionalInfo.child, allocator, scanner);
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
                const field_value = try recursiveDeserializeLeaky(field_type, allocator, scanner);
                @field(result, field.name) = field_value;
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
                        item.* = try recursiveDeserializeLeaky(pointerInfo.child, allocator, scanner);
                    }
                    return slice;
                },
                .One, .Many, .C => {
                    @compileError("Unsupported pointer type for deserialization: " ++ @typeName(T));
                },
            }
        },
        .@"union" => |unionInfo| {
            // unionInfo = struct {
            //     layout: ContainerLayout,
            //     tag_type: ?type,
            //     fields: []const UnionField,
            //     decls: []const Declaration,
            // };
            _ = unionInfo;
            @compileError("Unions are not supported for deserialization");
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

// Tests
comptime {
    _ = @import("codec/tests.zig");
    _ = @import("codec/encoder/tests.zig");
    _ = @import("codec/decoder/tests.zig");
    _ = @import("codec/encoder.zig");
}
