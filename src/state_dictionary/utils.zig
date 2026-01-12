//! This module provides utilities for efficiently handling null/optional values in the state dictionary.
//! When generating Merkle proofs for the state, we need to handle cases where parts of the state are
//! missing or null. Rather than storing null values directly in the state dictionary, we use this
//! managed pointer approach to:
//!
//! 1. Lazily initialize values only when needed
//! 2. Avoid allocating memory for null values that won't be included in proofs
//! 3. Properly clean up allocated memory when values are no longer needed
//!
//! This allows us to generate valid Merkle proofs even with an incomplete state, while maintaining
//! memory efficiency by only allocating what's necessary for the proof being generated.

const std = @import("std");

fn ManagedPtr(comptime T: type) type {
    const has_deinit = @hasDecl(T, "deinit");

    const needs_allocator_deinit = has_deinit and blk: {
        const deinit_info = @typeInfo(@TypeOf(T.deinit));
        break :blk (deinit_info == .@"fn" and deinit_info.@"fn".params.len > 1);
    };

    return struct {
        ptr: *const T,
        needs_free: bool,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.needs_free) {
                const ptr = @constCast(self.ptr);
                if (comptime has_deinit) {
                    if (comptime needs_allocator_deinit) {
                        ptr.deinit(allocator);
                    } else {
                        ptr.deinit();
                    }
                }
                allocator.destroy(self.ptr);
            }
            self.* = undefined;
        }
    };
}

pub fn getOrInitManaged(
    allocator: std.mem.Allocator,
    maybe_value: anytype,
    init_args: anytype,
) !ManagedPtr(std.meta.Child(std.meta.Child(@TypeOf(maybe_value)))) {
    const T = std.meta.Child(std.meta.Child(@TypeOf(maybe_value)));
    comptime {
        if (@typeInfo(@TypeOf(maybe_value)) != .pointer or
            @typeInfo(std.meta.Child(@TypeOf(maybe_value))) != .optional)
        {
            @compileError("maybe_value must be a pointer to optional type");
        }
        if (@typeInfo(@TypeOf(init_args)) != .@"struct" or
            !@typeInfo(@TypeOf(init_args)).@"struct".is_tuple)
        {
            @compileError("init_args must be a tuple");
        }
    }
    if (maybe_value.*) |*value| {
        return .{ .ptr = value, .needs_free = false };
    } else {

        const init_fn = @TypeOf(T.init);
        if (@typeInfo(init_fn) != .@"fn") {
            @compileError("T.init must be a function");
        }

        const ReturnType = @typeInfo(init_fn).@"fn".return_type.?;
        const returns_error = @typeInfo(ReturnType) == .error_union;

        if (comptime returns_error) {
            const SuccessType = @typeInfo(ReturnType).error_union.payload;
            if (SuccessType != T) {
                @compileError("T.init error union must return type T: T = " ++ @typeName(T));
            }
        } else if (ReturnType != T) {
            @compileError("T.init must return type T: T = " ++ @typeName(T));
        }

        const instance = try allocator.create(T);
        errdefer allocator.destroy(instance);

        instance.* = if (comptime returns_error)
            try @call(.auto, T.init, init_args)
        else
            @call(.auto, T.init, init_args);

        return .{ .ptr = instance, .needs_free = true };
    }
}
