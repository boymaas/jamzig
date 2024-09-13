const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn convert(comptime ToType: type, conversionFunctions: anytype, allocator: anytype, from: anytype) !ToType {
    var to: ToType = undefined;
    const toTypeInfo = @typeInfo(ToType);
    const fromTypeInfo = @typeInfo(@TypeOf(from));

    if (toTypeInfo != .@"struct" or fromTypeInfo != .@"struct") {
        return error.InvalidType;
    }

    inline for (toTypeInfo.@"struct".fields) |toField| {
        const fieldName = toField.name;
        const toFieldType = toField.type;
        const fromField = @field(from, fieldName);

        @field(to, fieldName) = try convertField(conversionFunctions, allocator, fromField, toFieldType);
    }

    return to;
}

/// This a generic function to free an converted object using the allocator.
pub fn free(allocator: Allocator, obj: anytype) void {
    const T = @TypeOf(obj);
    switch (@typeInfo(T)) {
        .@"struct" => |structInfo| {
            inline for (structInfo.fields) |field| {
                if (@typeInfo(field.type) == .pointer and @typeInfo(field.type).pointer.size == .Slice) {
                    allocator.free(@field(obj, field.name));
                } else {
                    free(allocator, @field(obj, field.name));
                }
            }
        },
        .pointer => |ptrInfo| {
            if (ptrInfo.size == .Slice) {
                allocator.free(obj);
            } else if (ptrInfo.size == .One) {
                free(allocator, obj.*);
            }
        },
        .optional => {
            if (obj) |value| {
                free(allocator, value);
            }
        },
        .array => {
            for (obj) |item| {
                free(allocator, item);
            }
        },
        else => {},
    }
}

fn convertField(conversionFunctions: anytype, allocator: anytype, fromValue: anytype, ToType: type) !ToType {
    const FromType = @TypeOf(fromValue);

    if (FromType == ToType) {
        return fromValue;
    } else {
        const toTypeInfo = @typeInfo(ToType);

        switch (toTypeInfo) {
            .optional => |optInfo| {
                if (fromValue) |value| {
                    const convertedValue = try convertField(conversionFunctions, allocator, value, optInfo.child);
                    return convertedValue;
                } else {
                    return null;
                }
            },
            .pointer => |ptrInfo| {
                if (ptrInfo.size == .Slice) {
                    const len = fromValue.len;
                    var toSlice = try allocator.alloc(ptrInfo.child, len);
                    for (fromValue, 0..) |item, i| {
                        toSlice[i] = try convertField(conversionFunctions, allocator, item, ptrInfo.child);
                    }
                    return toSlice;
                } else {
                    return error.UnsupportedPointerType;
                }
            },
            .array => |arrInfo| {
                var toArray: ToType = undefined;
                const fromTypeInfo = @typeInfo(FromType);
                switch (fromTypeInfo) {
                    .array => |fromArrInfo| {
                        if (fromArrInfo.len == arrInfo.len) {
                            inline for (0..arrInfo.len) |i| {
                                toArray[i] = try convertField(conversionFunctions, allocator, fromValue[i], arrInfo.child);
                            }
                        } else {
                            return error.ArrayLengthMismatch;
                        }
                    },
                    .pointer => |ptrInfo| {
                        if (ptrInfo.size == .Slice) {
                            if (fromValue.len != arrInfo.len) {
                                return error.SliceLengthMismatch;
                            }
                            for (fromValue, 0..) |item, i| {
                                toArray[i] = try convertField(conversionFunctions, allocator, item, arrInfo.child);
                            }
                        } else {
                            return error.UnsupportedPointerType;
                        }
                    },
                    else => {
                        return try callConversionFunction(conversionFunctions, allocator, fromValue, ToType);
                    },
                }
                return toArray;
            },
            .@"struct" => {
                const FromTypeInfo = @typeInfo(FromType);
                if (FromTypeInfo == .@"struct") {
                    return try convert(ToType, conversionFunctions, allocator, fromValue);
                } else {
                    // @compileLog("Calling conversion function for type: ", @typeName(FromType), " to ", @typeName(ToType));
                    return try callConversionFunction(conversionFunctions, allocator, fromValue, ToType);
                }
            },
            else => {
                // Handle special conversions
                if (@hasDecl(conversionFunctions, @typeName(FromType))) {
                    const conversionFn = @field(conversionFunctions, @typeName(FromType));
                    return conversionFn(fromValue);
                } else {
                    return error.NoConversionFunction;
                }
            },
        }
    }
}

fn callConversionFunction(conversionFunctions: anytype, allocator: anytype, fromValue: anytype, ToType: type) !ToType {
    const FromType = @TypeOf(fromValue);
    const typeNameInfo = comptime getTypeNameInfo(FromType);
    if (typeNameInfo.hasParameters) {
        if (@hasDecl(conversionFunctions, typeNameInfo.genericTypeName)) {
            const conversionFn = @field(conversionFunctions, typeNameInfo.genericTypeName);
            return conversionFn(allocator, fromValue);
        }
    }

    if (@hasDecl(conversionFunctions, typeNameInfo.typeNameWithoutPath)) {
        const conversionFn = @field(conversionFunctions, typeNameInfo.typeNameWithoutPath);
        const fnInfo = @typeInfo(@TypeOf(conversionFn));
        if (fnInfo == .@"fn" and fnInfo.@"fn".params.len == 2) {
            return conversionFn(allocator, fromValue);
        } else {
            return conversionFn(fromValue);
        }
    } else {
        std.debug.print("No conversion function found for type: {s} (generic: {s})\n", .{ typeNameInfo.typeNameWithoutPath, typeNameInfo.genericTypeName });
        return error.NoConversionFunction;
    }
}

fn getTypeNameInfo(comptime T: type) struct { typeNameWithoutPath: []const u8, genericTypeName: []const u8, hasParameters: bool } {
    const fullTypeName = @typeName(T);
    const lastDotIndex = comptime std.mem.lastIndexOf(u8, fullTypeName, ".") orelse 0;
    const typeNameWithoutPath = comptime fullTypeName[lastDotIndex + 1 ..];
    const genericTypeName = comptime std.mem.sliceTo(typeNameWithoutPath, '(');
    const hasParameters = std.mem.indexOfScalar(u8, typeNameWithoutPath, '(') != null;
    return .{
        .typeNameWithoutPath = typeNameWithoutPath,
        .genericTypeName = genericTypeName,
        .hasParameters = hasParameters,
    };
}
