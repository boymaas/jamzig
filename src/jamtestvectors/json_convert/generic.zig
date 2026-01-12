const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn convert(comptime ToType: type, conversionFunctions: anytype, allocator: anytype, from: anytype) !ToType {
    return try convertField(
        conversionFunctions,
        allocator,
        from,
        ToType,
    );
}

fn convertField(conversionFunctions: anytype, allocator: anytype, fromValue: anytype, ToType: type) !ToType {
    const FromType = @TypeOf(fromValue);

    if (FromType == ToType) {
        return fromValue;
    } else {
        const toTypeInfo = @typeInfo(ToType);

        switch (toTypeInfo) {
            .int => |_| {
                return @as(ToType, @intCast(fromValue));
            },
            .optional => |optInfo| {
                if (fromValue) |value| {
                    const convertedValue = try convertField(conversionFunctions, allocator, value, optInfo.child);
                    return convertedValue;
                } else {
                    return null;
                }
            },
            .pointer => |ptrInfo| {
                if (ptrInfo.size == .slice) {
                    const fromTypeInfo = @typeInfo(FromType);
                    switch (fromTypeInfo) {
                        .pointer => |fromPtrInfo| {
                            if (fromPtrInfo.size == .slice) {
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
                        .array => |fromArrInfo| {
                            const len = fromArrInfo.len;
                            var toSlice = try allocator.alloc(ptrInfo.child, len);
                            for (fromValue, 0..) |item, i| {
                                toSlice[i] = try convertField(conversionFunctions, allocator, item, ptrInfo.child);
                            }
                            return toSlice;
                        },
                        else => {
                            return try callConversionFunction(conversionFunctions, allocator, fromValue, ToType);
                        },
                    }
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

                // First check if we have a direct typemapping function available for this struct type
                const toTypeNameInfo = comptime getTypeNameInfo(ToType);
                if (@hasDecl(conversionFunctions, toTypeNameInfo.typeNameWithoutPath)) {
                    return try callConversionFunction(conversionFunctions, allocator, fromValue, ToType);
                }

                // If no direct mapping function exists, proceed with field-by-field conversion
                var to: ToType = undefined;
                if (FromTypeInfo == .@"struct") {
                    inline for (toTypeInfo.@"struct".fields) |toField| {
                        const toFieldName = toField.name;
                        const toFieldType = toField.type;
                        const fromFieldValue = @field(fromValue, toFieldName);

                        @field(to, toFieldName) = try convertField(conversionFunctions, allocator, fromFieldValue, toFieldType);
                    }
                    return to;
                } else {
                    return try callConversionFunction(conversionFunctions, allocator, fromValue, ToType);
                }
            },
            else => {
                // Handle special conversions
                return try callConversionFunction(conversionFunctions, allocator, fromValue, ToType);
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
            // NOTE; try as allocation could fail
            return try conversionFn(allocator, fromValue);
        } else {
            return conversionFn(fromValue);
        }
    } else {
        @compileError(
            "No conversion function found for type: " ++ typeNameInfo.typeNameWithoutPath ++ " (generic: " ++ typeNameInfo.genericTypeName ++ ")",
        );
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

pub fn free(allocator: Allocator, obj: anytype) void {
    const T = @TypeOf(obj);

    switch (@typeInfo(T)) {
        .@"struct" => |structInfo| {
            inline for (structInfo.fields) |field| {
                free(allocator, @field(obj, field.name));
            }
        },
        .pointer => |ptrInfo| {
            if (ptrInfo.size == .slice) {
                for (obj) |item| {
                    free(allocator, item);
                }
                allocator.free(obj);
            } else if (ptrInfo.size == .One) {
                free(allocator, obj.*);
                allocator.destroy(obj);
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
        .@"union" => |unionInfo| {
            if (unionInfo.tag_type) |_| {
                switch (obj) {
                    inline else => |field| {
                        free(allocator, field);
                    },
                }
            } else {
                @compileError("Cannot free untagged union");
            }
        },
        else => {},
    }
}
