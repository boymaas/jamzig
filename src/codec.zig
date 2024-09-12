const std = @import("std");
const json = std.json;
const Scanner = @import("codec/scanner.zig").Scanner;

pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, data: []u8) !T {
    const scanner = Scanner.initCompleteInput(data);
    return try recursiveDeserializeLeaky(T, allocator, scanner);
}

/// `scanner_or_reader` must be either a `*std.json.Scanner` with complete input or a `*std.json.Reader`.
/// Allocations made during this operation are not carefully tracked and may not be possible to individually clean up.
/// It is recommended to use a `std.heap.ArenaAllocator` or similar.
fn recursiveDeserializeLeaky(comptime T: type, allocator: std.mem.Allocator, scanner: Scanner) !T {
    _ = allocator;
    _ = scanner;

    switch (@typeInfo(T)) {
        .int => {
            // Handle integer deserialization
            @compileError("Integer deserialization not implemented yet");
        },
        .float => {
            // Handle float deserialization
            @compileError("Float deserialization not implemented yet");
        },
        .@"struct" => {
            // Handle struct deserialization
            @compileError("Struct deserialization not implemented yet");
        },
        .array => {
            // Handle array deserialization
            @compileError("Array deserialization not implemented yet");
        },
        .pointer => {
            // Handle pointer (slice) deserialization
            @compileError("Pointer/slice deserialization not implemented yet");
        },
        else => {
            @compileError("Unsupported type for deserialization");
        },
    }
}

// Tests
comptime {
    _ = @import("codec/tests.zig");
    _ = @import("codec/encoder/tests.zig");
    _ = @import("codec/decoder/tests.zig");
    _ = @import("codec/encoder.zig");
}
