const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const time = @import("time.zig");
const Params = @import("jam_params.zig").Params;

pub const Error = error{
    UninitializedBaseField,
    UninitializedTransientField,
    CanOnlyModifyTransient,
    CanOnlyCreateTransient,
    CanOnlyInializeTransient,
    PreviousStateRequired,
    StateTransitioned,
    PrimeFieldAlreadySet,
    DeepCloneError,
} || error{OutOfMemory};

const DaggerState = enum {
    beta_dagger,
    delta_double_dagger,
    rho_dagger,
    rho_double_dagger,
};

const DaggerStateInfo = struct {
    name: []const u8,
    Type: type,
    requires_previous: bool,
    blocks_next: bool,
};

pub fn StateTransition(comptime params: Params) type {
    return struct {
        const Self = @This();
        const State = state.JamState(params);

        allocator: std.mem.Allocator,
        time: params.Time(),
        base: *const state.JamState(params),
        prime: state.JamState(params),

        // Intermediate states
        beta_dagger: ?state.Beta = null,
        delta_double_dagger: ?state.Delta = null,
        rho_dagger: ?state.Rho(params.core_count) = null,
        rho_double_dagger: ?state.Rho(params.core_count) = null,

        pub fn init(
            allocator: std.mem.Allocator,
            base_state: *const state.JamState(params),
            transition_time: params.Time(),
        ) !Self {
            return Self{
                .allocator = allocator,
                .base = base_state,
                .prime = try state.JamState(params).init(allocator),
                .time = transition_time,
            };
        }

        pub fn create(
            allocator: std.mem.Allocator,
            base_state: *const state.JamState(params),
            transition_time: params.Time(),
        ) !*Self {
            const ptr = try allocator.create(Self);
            ptr.* = try Self.init(allocator, base_state, transition_time);
            return ptr;
        }

        pub fn ensure(self: *Self, comptime field: STAccessors(State)) Error!STAccessorPointerType(STBaseType(State, field), field) {
            const builtin = @import("builtin");
            const name = @tagName(field);

            const is_prime = comptime std.mem.endsWith(u8, name, "_prime");
            const base_name = if (is_prime) name[0 .. name.len - 6] else name;
            const prime_field = &@field(self.prime, base_name);

            if (is_prime) {
                if (prime_field.* == null) {
                    const base_field = &@field(self.base, base_name);
                    if (comptime builtin.mode == .Debug) {
                        if (base_field.* == null) {
                            @panic("UninitializedBaseField: " ++ name);
                        }
                    }
                    prime_field.* = try self.cloneField(base_field.*);
                }
                return &prime_field.*.?;
            } else {
                const base_field = &@field(self.base, base_name);
                if (comptime builtin.mode == .Debug) {
                    if (base_field.* == null) {
                        @panic("UninitializedBaseField: " ++ name);
                    }
                }
                return &base_field.*.?;
            }
        }

        pub fn createTransient(self: *Self, comptime field: STAccessors(State), value: STBaseType(State, field)) Error!void {
            const builtin = @import("builtin");

            const name = @tagName(field);

            if (builtin.mode == .Debug and
                !comptime std.mem.endsWith(u8, name, "_prime"))
            {
                return Error.CanOnlyCreateTransient;
            }

            const base_name = name[0 .. name.len - 6];
            const prime_field = &@field(self.prime, base_name);

            if (comptime builtin.mode == .Debug) {
                if (prime_field.* != null) return Error.PrimeFieldAlreadySet;
            }

            prime_field.* = value;
        }

        pub fn initTransientWithBase(self: *Self, comptime field: STAccessors(State)) Error!STAccessorPointerType(STBaseType(State, field), field) {
            const builtin = @import("builtin");
            const name = @tagName(field);

            if ((!comptime std.mem.endsWith(u8, name, "_prime")) and
                builtin.mode == .Debug)
            {
                return Error.CanOnlyInializeTransient;
            }

            const base_name = name[0 .. name.len - 6];
            const base_field = &@field(self.base, base_name);
            const prime_field = &@field(self.prime, base_name);
            if (comptime builtin.mode == .Debug) {
                if (prime_field.* != null) return Error.PrimeFieldAlreadySet;
                if (base_field.* == null) return Error.UninitializedBaseField;
            }

            prime_field.* = try self.cloneField(base_field.*);

            return &prime_field.*.?;
        }

        pub inline fn get(self: *Self, comptime field: STAccessors(State)) !STAccessorPointerType(STBaseType(State, field), field) {
            const builtin = @import("builtin");

            const name = @tagName(field);
            const is_prime = comptime std.mem.endsWith(u8, name, "_prime");

            const base_name = if (is_prime)
                name[0 .. name.len - 6]
            else
                name;

            if (comptime builtin.mode == .Debug) {
                if (is_prime) {
                    const prime_field = &@field(self.prime, base_name);
                    if (prime_field.* == null) {
                        return Error.UninitializedTransientField;
                    }
                    return &prime_field.*.?;
                } else {
                    const base_field = &@field(self.base, base_name);
                    if (base_field.* == null) {
                        return error.UninitializedBaseField;
                    }
                    return &base_field.*.?;
                }
            } else {
                const field_ptr = if (comptime std.mem.endsWith(u8, name, "_prime"))
                    &@field(self.prime, base_name)
                else
                    &@field(self.base, base_name);
                return &field_ptr.*.?;
            }
        }

        /// Check if a field is initialized (non-null) in base state
        pub fn hasBase(self: *const Self, comptime field: STAccessors(State)) bool {
            const name = @tagName(field);
            const base_name = if (comptime std.mem.endsWith(u8, name, "_prime"))
                name[0 .. name.len - 6]
            else
                name;

            const base_field = @field(self.base, base_name);
            return base_field != null;
        }

        pub fn hasPrime(self: *const Self, comptime field: STAccessors(State)) bool {
            const name = @tagName(field);
            const base_name = if (comptime std.mem.endsWith(u8, name, "_prime"))
                name[0 .. name.len - 6]
            else
                name;

            const prime_field = @field(self.prime, base_name);
            return prime_field != null;
        }

        fn cloneField(self: *Self, field: anytype) Error!@TypeOf(field.?) {
            const T = @TypeOf(field.?);
            return switch (@typeInfo(T)) {
                .@"struct", .@"union" => if (@hasDecl(T, "deepClone")) blk: {
                    const info = @typeInfo(@TypeOf(T.deepClone));
                    break :blk if (info == .@"fn" and info.@"fn".params.len > 1 and
                        info.@"fn".params[1].type == std.mem.Allocator)
                        field.?.deepClone(self.allocator) catch {
                            return Error.DeepCloneError;
                        }
                    else
                        field.?.deepClone() catch {
                            return Error.DeepCloneError;
                        };
                } else @compileError("All structs / unions must have a deepClone method"),
                else => field.?,
            };
        }

        pub fn cloneBaseAndMergeWithPrime(self: *Self) !State {
            var cloned = try self.base.deepClone(self.allocator);
            try cloned.merge(&self.prime, self.allocator);
            return cloned;
        }

        pub fn mergePrimeOntoBase(self: *Self) !void {
            try @constCast(self.base).merge(&self.prime, self.allocator);
        }

        pub fn createMergedView(self: *const Self) State {
            var merged_view = State{};

            // For each field, take from prime if present, otherwise from base
            inline for (std.meta.fields(State)) |field| {
                const prime_value = @field(self.prime, field.name);
                if (prime_value != null) {
                    @field(merged_view, field.name) = prime_value;
                } else {
                    @field(merged_view, field.name) = @field(self.base, field.name);
                }
            }

            return merged_view;
        }

        /// IMPORTANT: This is used for fork detection in the fuzz protocol.
        /// We need to know the resulting state root before deciding whether to commit.
        pub fn computeStateRoot(self: *const Self, allocator: std.mem.Allocator) !types.StateRoot {
            const merged_view = self.createMergedView();
            return try merged_view.buildStateRoot(allocator);
        }

        pub fn deinit(self: *Self) void {
            self.prime.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            self.prime.deinit(self.allocator);
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn buildPrimeView(self: *Self) state.JamStateView(params) {
            var view = state.JamStateView(params).init();

            inline for (comptime std.meta.fieldNames(state.JamStateView(params))) |field_name| {
                const prime_field = &@field(self.prime, field_name);
                const base_field = &@field(self.base, field_name);

                @field(view, field_name) = if (prime_field.*) |*p|
                    p
                else if (base_field.*) |*b|
                    b
                else
                    null;
            }

            return view;
        }
        pub fn buildBaseView(self: *Self) state.JamStateView(params) {
            var view = state.JamStateView(params).init();

            inline for (comptime std.meta.fieldNames(state.JamStateView(params))) |field_name| {
                const base_field = &@field(self.base, field_name);

                @field(view, field_name) = if (base_field.*) |*b|
                    b
                else
                    null;
            }

            return view;
        }
    };
}

pub fn STBaseType(comptime T: anytype, comptime field: anytype) type {
    const field_name = @tagName(field);

    const base_name = if (std.mem.endsWith(u8, field_name, "_prime"))
        field_name[0 .. field_name.len - 6]
    else
        field_name;

    @setEvalBranchQuota(8000);
    const field_enum = std.meta.stringToEnum(std.meta.FieldEnum(T), base_name) //
        orelse @compileError("Invalid field name: " ++ base_name);

    return std.meta.Child(std.meta.fieldInfo(T, field_enum).type);
}

pub fn STAccessorPointerType(comptime T: anytype, comptime field: anytype) type {
    const field_name = @tagName(field);

    return if (std.mem.endsWith(u8, field_name, "_prime"))
        *T
    else
        *const T;
}

pub fn STAccessors(comptime T: type) type {
    const field_infos = std.meta.fields(T);

    var enumFields: [field_infos.len * 2]std.builtin.Type.EnumField = undefined;
    var decls = [_]std.builtin.Type.Declaration{};
    inline for (field_infos, 0..) |field, i| {
        const o = 2 * i;
        enumFields[o] = .{
            .name = field.name ++ "",
            .value = o,
        };
        enumFields[o + 1] = .{
            .name = field.name ++ "_prime",
            .value = o + 1,
        };
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, (field_infos.len * 2) - 1),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}
