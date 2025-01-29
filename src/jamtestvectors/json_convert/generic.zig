const std = @import("std");
const Allocator = std.mem.Allocator;

const tracing = @import("../../tracing.zig");
const trace = tracing.scoped(.convert_generic);

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

/// This a generic function to free an generic converted object using the allocator.
pub fn free(allocator: Allocator, obj: anytype) void {
    const T = @TypeOf(obj);
    const span = trace.span(.free);
    defer span.deinit();

    span.debug("Freeing object of type: {s}", .{@typeName(T)});

    switch (@typeInfo(T)) {
        .@"struct" => |structInfo| {
            const struct_span = span.child(.struct_fields);
            defer struct_span.deinit();

            inline for (structInfo.fields) |field| {
                struct_span.debug("Freeing field: {s}", .{field.name});
                free(allocator, @field(obj, field.name));
            }
        },
        .pointer => |ptrInfo| {
            if (ptrInfo.size == .slice) {
                const slice_span = span.child(.slice);
                defer slice_span.deinit();

                slice_span.debug("Freeing slice elements", .{});
                for (obj) |item| {
                    free(allocator, item);
                }
                slice_span.debug("Freeing slice", .{});
                allocator.free(obj);
            } else if (ptrInfo.size == .One) {
                const ptr_span = span.child(.single_pointer);
                defer ptr_span.deinit();

                ptr_span.debug("Freeing single pointer", .{});
                free(allocator, obj.*);
                allocator.destroy(obj);
            } else {
                span.warn("Unsupported pointer size", .{});
            }
        },
        .optional => {
            const opt_span = span.child(.optional);
            defer opt_span.deinit();

            if (obj) |value| {
                opt_span.debug("Freeing optional value", .{});
                free(allocator, value);
            } else {
                opt_span.debug("Optional is null, nothing to free", .{});
            }
        },
        .array => {
            const arr_span = span.child(.array);
            defer arr_span.deinit();

            arr_span.debug("Freeing array elements", .{});
            for (obj, 0..) |item, index| {
                arr_span.debug("Freeing array element at index: {d}", .{index});
                free(allocator, item);
            }
        },
        .@"union" => |unionInfo| {
            if (unionInfo.tag_type) |_| {
                const union_span = span.child(.tagged_union);
                defer union_span.deinit();

                union_span.debug("Freeing tagged union", .{});
                switch (obj) {
                    inline else => |field| {
                        union_span.debug("Freeing union field", .{});
                        free(allocator, field);
                    },
                }
            } else {
                @compileError("Cannot free untagged union");
            }
        },
        else => {
            span.debug("No specific free action for type: {s}", .{@typeName(T)});
        },
    }
    span.debug("Finished freeing object", .{});
}
