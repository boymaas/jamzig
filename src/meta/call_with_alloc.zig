const std = @import("std");

// Helper function to check if a type is a struct or union
pub fn isComplexType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .@"struct" or type_info == .@"union";
}

// Generic function to call a method on a type with proper parameter handling
fn callWithAllocator(comptime method_name: []const u8, value: anytype, allocator: std.mem.Allocator) void {
    const ValueType = std.meta.Child(@TypeOf(value));

    // return early, as we have nothing to call here
    if (!comptime isComplexType(ValueType)) {
        return;
    }

    // Check if the type has the required method
    if (!@hasDecl(ValueType, method_name)) {
        @panic("Please implement " ++ method_name ++ " for: " ++ @typeName(ValueType));
    }

    // Get the type information about the method
    const method_info = @typeInfo(@TypeOf(@field(ValueType, method_name)));

    // Ensure it's actually a function
    if (method_info != .@"fn") {
        @panic(method_name ++ " must be a function for: " ++ @typeName(ValueType));
    }

    // Check the number of parameters the method expects
    const params_len = method_info.@"fn".params.len;

    // Call the method with the appropriate number of parameters
    switch (params_len) {
        1 => @field(ValueType, method_name)(value),
        2 => @field(ValueType, method_name)(value, allocator),
        else => @panic(method_name ++ " must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
    }
}

// Tools for meta programming
pub fn callDeinit(value: anytype, allocator: std.mem.Allocator) void {
    callWithAllocator("deinit", value, allocator);
}

// Tools for meta programming
pub fn callDeepClone(value: anytype, allocator: std.mem.Allocator) void {
    callWithAllocator("deepClone", value, allocator);
}
