const std = @import("std");

// Helper function to check if a type is a struct or union
pub fn isComplexType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .@"struct" or type_info == .@"union";
}

// Tools for meta programming
pub fn callDeinit(value: anytype, allocator: std.mem.Allocator) void {
    const ValueType = std.meta.Child(@TypeOf(value));

    // return early, as we have nothing to call here
    if (!comptime isComplexType(ValueType)) {
        return;
    }

    // std.debug.print("deallocating " ++ @typeName(@TypeOf(value)) ++ "\n", .{});

    // Check if the type has a deinit method
    if (!@hasDecl(ValueType, "deinit")) {
        @panic("Please implement deinit for: " ++ @typeName(ValueType));
    }

    // Get the type information about the deinit function
    const deinit_info = @typeInfo(@TypeOf(@field(ValueType, "deinit")));

    // Ensure it's actually a function
    if (deinit_info != .@"fn") {
        @panic("deinit must be a function for: " ++ @typeName(ValueType));
    }

    // Check the number of parameters the deinit function expects
    const params_len = deinit_info.@"fn".params.len;

    // Call deinit with the appropriate number of parameters
    switch (params_len) {
        1 => value.deinit(),
        2 => value.deinit(allocator),
        else => @panic("deinit must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
    }
}
