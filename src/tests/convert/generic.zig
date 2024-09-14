const std = @import("std");
const Allocator = std.mem.Allocator;

const trace = @import("../../tracing.zig").src;

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
                if (ptrInfo.size == .Slice) {
                    const fromTypeInfo = @typeInfo(FromType);
                    switch (fromTypeInfo) {
                        .pointer => |fromPtrInfo| {
                            if (fromPtrInfo.size == .Slice) {
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
                    // @compileLog("Calling conversion function for type: ", @typeName(FromType), " to ", @typeName(ToType));
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

/// This a generic function to free an generic converted object using the allocator.
pub fn free(allocator: Allocator, obj: anytype) void {
    const T = @TypeOf(obj);
    trace(@src(), "Freeing object of type: {s}\n", .{@typeName(T)});
    switch (@typeInfo(T)) {
        .@"struct" => |structInfo| {
            trace(@src(), "Freeing struct fields\n", .{});
            inline for (structInfo.fields) |field| {
                trace(@src(), "Freeing field: {s}\n", .{field.name});
                free(allocator, @field(obj, field.name));
            }
        },
        .pointer => |ptrInfo| {
            if (ptrInfo.size == .Slice) {
                trace(@src(), "Freeing slice elements\n", .{});
                for (obj) |item| {
                    free(allocator, item);
                }
                trace(@src(), "Freeing slice\n", .{});
                allocator.free(obj);
            } else if (ptrInfo.size == .One) {
                trace(@src(), "Freeing single pointer\n", .{});
                free(allocator, obj.*);
                allocator.destroy(obj);
            } else {
                trace(@src(), "Unsupported pointer size\n", .{});
            }
        },
        .optional => {
            trace(@src(), "Freeing optional\n", .{});
            if (obj) |value| {
                free(allocator, value);
            } else {
                trace(@src(), "Optional is null, nothing to free\n", .{});
            }
        },
        .array => {
            trace(@src(), "Freeing array elements\n", .{});
            for (obj, 0..) |item, index| {
                trace(@src(), "Freeing array element at index: {d}\n", .{index});
                free(allocator, item);
            }
        },
        .@"union" => |unionInfo| {
            if (unionInfo.tag_type) |_| {
                trace(@src(), "Freeing tagged union\n", .{});
                switch (obj) {
                    inline else => |field| {
                        trace(@src(), "Freeing union field {any}\n", .{field});
                        free(allocator, field);
                    },
                }
            } else {
                @compileError("Cannot free untagged union");
            }
        },
        else => {
            trace(@src(), "No specific free action for type: {s}\n", .{@typeName(T)});
        },
    }
    trace(@src(), "Finished freeing object of type: {s}\n", .{@typeName(T)});
}
