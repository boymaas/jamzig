const std = @import("std");

pub fn isComplexType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .@"struct" or type_info == .@"union";
}

pub fn DerefPointerType(comptime T: type) type {
    return if (@typeInfo(T) == .pointer)
        std.meta.Child(T)
    else
        T;
}

pub fn callDeinit(value: anytype, allocator: std.mem.Allocator) void {
    const ValueType = DerefPointerType(@TypeOf(value));

    if (!@hasDecl(ValueType, "deinit")) {
        @panic("Please implement deinit for: " ++ @typeName(ValueType));
    }

    const method_info = @typeInfo(@TypeOf(@field(ValueType, "deinit")));

    if (method_info != .@"fn") {
        @panic("deinit must be a function for: " ++ @typeName(ValueType));
    }

    const params = method_info.@"fn".params;
    const params_0_info = @typeInfo(params[0].type.?);
    const value_info = @typeInfo(@TypeOf(value));

    if ((params_0_info == .pointer and value_info == .pointer) or (params_0_info != .pointer and value_info != .pointer)) {
        switch (params.len) {
            1 => return @field(ValueType, "deinit")(value),
            2 => return @field(ValueType, "deinit")(value, allocator),
            else => @panic("deinit must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
        }
    } else if (params_0_info != .pointer and value_info == .pointer) {
        switch (params.len) {
            1 => return @field(ValueType, "deinit")(value.*),
            2 => return @field(ValueType, "deinit")(value.*, allocator),
            else => @panic("deinit must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
        }
    } else {
        switch (params.len) {
            1 => return @field(ValueType, "deinit")(@constCast(&value)),
            2 => return @field(ValueType, "deinit")(@constCast(&value), allocator),
            else => @panic("deinit must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
        }
    }
}

pub fn callDeepClone(value: anytype, allocator: std.mem.Allocator) !DerefPointerType(@TypeOf(value)) {
    const ValueType = DerefPointerType(@TypeOf(value));

    if (!@hasDecl(ValueType, "deepClone")) {
        @panic("Please implement deepClone for: " ++ @typeName(ValueType));
    }

    const method_info = @typeInfo(@TypeOf(@field(ValueType, "deepClone")));

    if (method_info != .@"fn") {
        @panic("deepClone must be a function for: " ++ @typeName(ValueType));
    }

    const params_len = method_info.@"fn".params.len;

    return switch (params_len) {
        1 => @field(ValueType, "deepClone")(value),
        2 => @field(ValueType, "deepClone")(value, allocator),
        else => @panic("deepClone must take 0 or 1 parameters for: " ++ @typeName(ValueType)),
    };
}
