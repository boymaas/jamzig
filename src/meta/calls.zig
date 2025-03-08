const std = @import("std");

// Helper function to check if a type is a struct or union
pub fn isComplexType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .@"struct" or type_info == .@"union";
}

// Helper function to get the value type, handling both pointers and direct values
pub fn DerefPointerType(comptime T: type) type {
    return if (@typeInfo(T) == .pointer)
        std.meta.Child(T)
    else
        T;
}

// Tools for meta programming - deinit doesn't return a value
pub fn callDeinit(value: anytype, allocator: std.mem.Allocator) void {
    const ValueType = DerefPointerType(@TypeOf(value));

    // Check if the type has the required method
    if (!@hasDecl(ValueType, "deinit")) {
        @panic("Please implement deinit for: " ++ @typeName(ValueType));
    }

    // Get the type information about the method
    const method_info = @typeInfo(@TypeOf(@field(ValueType, "deinit")));

    // Ensure it's actually a function
    if (method_info != .@"fn") {
        @panic("deinit must be a function for: " ++ @typeName(ValueType));
    }

    // Check the number of parameters the method expects
    const params_len = method_info.@"fn".params.len;

    // Call the method with the appropriate number of parameters
    switch (params_len) {
        1 => return @field(ValueType, "deinit")(value),
        2 => return @field(ValueType, "deinit")(value, allocator),
        else => @panic("deinit must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
    }
}

// Tools for meta programming - deepClone returns a cloned value
pub fn callDeepClone(value: anytype, allocator: std.mem.Allocator) !DerefPointerType(@TypeOf(value)) {
    const ValueType = DerefPointerType(@TypeOf(value));

    // Check if the type has the required method
    if (!@hasDecl(ValueType, "deepClone")) {
        @panic("Please implement deepClone for: " ++ @typeName(ValueType));
    }

    // Get the type information about the method
    const method_info = @typeInfo(@TypeOf(@field(ValueType, "deepClone")));

    // Ensure it's actually a function
    if (method_info != .@"fn") {
        @panic("deepClone must be a function for: " ++ @typeName(ValueType));
    }

    // Check the number of parameters the method expects
    const params_len = method_info.@"fn".params.len;

    // Call the method with the appropriate number of parameters
    return switch (params_len) {
        1 => @field(ValueType, "deepClone")(value),
        2 => @field(ValueType, "deepClone")(value, allocator),
        else => @panic("deepClone must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
    };
}
