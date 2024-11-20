const std = @import("std");

pub inline fn deepClone(comptime T: type, this: *const T, allocator: std.mem.Allocator) !T {
    const tyinfo = comptime @typeInfo(T);
    if (comptime tyinfo == .pointer) {
        if (comptime tyinfo.pointer.size == .One) {
            const TT = std.meta.Child(T);
            return deepClone(TT, this.*, allocator);
        }
        if (comptime tyinfo.pointer.size == .Slice) {
            var slice = try allocator.alloc(tyinfo.pointer.child, this.len);
            for (this.*, 0..) |*e, i| {
                slice[i] = try deepClone(tyinfo.pointer.child, e, allocator);
            }
            return slice;
        }
        @compileError("Deep clone not supported for this kind of pointer: " ++ @tagName(tyinfo.Pointer.size) ++ " (" ++ @typeName(T) ++ ")");
    }
    if (comptime tyinfo == .optional) {
        const TT = std.meta.Child(T);
        if (this.* != null) return try deepClone(TT, &this.*.?, allocator);
        return null;
    }

    // Handle primitive types directly
    switch (comptime tyinfo) {
        .int, .float, .bool, .@"enum" => return this.*,
        else => {},
    }

    if (!@hasDecl(T, "deepClone")) {
        @compileError(@typeName(T) ++ " does not have a deepClone() function");
    }

    return T.deepClone(this, allocator);
}
