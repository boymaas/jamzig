const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const time = @import("time.zig");
const Params = @import("jam_params.zig").Params;

pub const Error = error{
    UninitializedBaseField,
    PreviousStateRequired,
    StateTransitioned,
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

/// StateTransition implements a pattern for state transitions.
/// It maintains both the original (base) state and a transitioning (prime) state,
/// creating copies of state fields only when they need to be modified.
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

        const dagger_states = std.StaticStringMap(DaggerStateInfo).initComptime(.{
            .{ "beta_dagger", .{
                .name = "beta",
                .Type = state.Beta,
                .requires_previous = true,
                .blocks_next = false,
            } },
            .{ "delta_double_dagger", .{
                .name = "delta",
                .Type = state.Delta,
                .requires_previous = true,
                .blocks_next = false,
            } },
            .{ "rho_dagger", .{
                .name = "rho",
                .Type = state.Rho(params.core_count),
                .requires_previous = true,
                .blocks_next = true,
            } },
            .{ "rho_double_dagger", .{
                .name = "rho",
                .Type = state.Rho(params.core_count),
                .requires_previous = true,
                .blocks_next = false,
            } },
        });

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

        fn handleDaggerState(
            self: *Self,
            comptime name: []const u8,
            comptime field: STAccessors(State),
        ) !?STAccessorPointerType(State, field) {
            if (dagger_states.get(name)) |info| {
                const prime_field = &@field(self.prime, info.name);
                const dagger_field = &@field(self, name);

                if (prime_field.* == null) return Error.PreviousStateRequired;
                if (dagger_field.* == null) {
                    dagger_field.* = try prime_field.*.?.deepClone(self.allocator);
                }
                return &dagger_field.*.?;
            }
            return null;
        }

        pub fn ensure(self: *Self, comptime field: STAccessors(State)) Error!STAccessorPointerType(State, field) {
            const name = @tagName(field);

            // Handle dagger states
            if (try self.handleDaggerState(name, field)) |result| {
                return result;
            }

            // Handle regular prime transitions
            const is_prime = comptime std.mem.endsWith(u8, name, "_prime");
            const base_name = if (is_prime) name[0 .. name.len - 6] else name;
            const base_field = &@field(self.base, base_name);
            const prime_field = &@field(self.prime, base_name);

            if (base_field.* == null) {
                return Error.UninitializedBaseField;
            }

            if (is_prime) {
                if (prime_field.* == null) {
                    prime_field.* = try self.cloneField(base_field.*);
                }
                return &prime_field.*.?;
            } else {
                return &base_field.*.?;
            }
        }

        fn cloneField(self: *Self, field: anytype) !@TypeOf(field.?) {
            const T = @TypeOf(field.?);
            return switch (@typeInfo(T)) {
                .@"struct", .@"union" => if (@hasDecl(T, "deepClone")) blk: {
                    const info = @typeInfo(@TypeOf(T.deepClone));
                    break :blk if (info == .@"fn" and info.@"fn".params.len > 1 and
                        info.@"fn".params[1].type == std.mem.Allocator)
                        try field.?.deepClone(self.allocator)
                    else
                        try field.?.deepClone();
                } else @compileError("All structs / unions must have a deepClone method"),
                else => field.?,
            };
        }

        fn initializeDaggerState(
            self: *Self,
            comptime name: []const u8,
            value: anytype,
        ) !bool {
            if (dagger_states.get(name)) |_| {
                const field_ptr = &@field(self, name);
                if (field_ptr.* != null) return Error.StateTransitioned;
                field_ptr.* = value;
                return true;
            }
            return false;
        }

        pub fn initialize(self: *Self, comptime field: STAccessors(State), value: STBaseType(State, field)) Error!void {
            const name = @tagName(field);

            // Handle dagger states
            if (try self.initializeDaggerState(name, value)) {
                return;
            }

            // Ensure we're only initializing prime states
            if (!std.mem.endsWith(u8, name, "_prime")) {
                return Error.StateTransitioned;
            }

            // Handle prime state initialization
            const base_name = name[0 .. name.len - 6];
            const prime_field = &@field(self.prime, base_name);

            if (prime_field.* != null) return Error.StateTransitioned;
            prime_field.* = value;
        }

        fn overwriteDaggerState(
            self: *Self,
            name: []const u8,
            value: anytype,
        ) !bool {
            if (dagger_states.get(name)) |_| {
                const field_ptr = &@field(self, name);
                if (field_ptr.* == null) return Error.PreviousStateRequired;
                field_ptr.* = value;
                return true;
            }
            return false;
        }

        pub fn overwrite(self: *Self, comptime field: STAccessors(State), value: STBaseType(State, field)) Error!void {
            const name = @tagName(field);

            // Handle dagger states
            if (try self.overwriteDaggerState(name, value)) {
                return;
            }

            // Handle regular fields
            const base_name = if (std.mem.endsWith(u8, name, "_prime"))
                name[0 .. name.len - 6]
            else
                name;

            const field_ptr = &@field(if (std.mem.endsWith(u8, name, "_prime"))
                self.prime
            else
                self.base, base_name);

            if (field_ptr.* == null) return Error.UninitializedBaseField;
            field_ptr.* = value;
        }

        /// frees all owned memory except non-owned self.base
        pub fn deinit(self: *Self) void {
            self.prime.deinit(self.allocator);
            inline for (comptime dagger_states.keys()) |k| {
                if (@field(self, k)) |*field| field.deinit();
            }
        }
    };
}

// Rest of the helper functions remain the same...

/// Returns the base type for a given field accessor
pub fn STBaseType(comptime T: anytype, comptime field: anytype) type {
    const field_name = @tagName(field);
    // Handle special transition states
    if (std.mem.eql(u8, field_name, "beta_dagger")) {
        return state.Beta;
    }
    if (std.mem.eql(u8, field_name, "delta_double_dagger")) {
        return state.Delta;
    }
    if (std.mem.eql(u8, field_name, "rho_dagger") or std.mem.eql(u8, field_name, "rho_double_dagger")) {
        return state.Rho;
    }

    // For regular fields, strip _prime suffix if present
    const base_name = if (std.mem.endsWith(u8, field_name, "_prime"))
        field_name[0 .. field_name.len - 6]
    else
        field_name;

    // Get the type of the base field
    // Convert string to field enum
    const field_enum = std.meta.stringToEnum(std.meta.FieldEnum(T), base_name) //
    orelse @compileError("Invalid field name: " ++ base_name);

    return std.meta.Child(std.meta.fieldInfo(T, field_enum).type);
}

/// Returns the appropriate pointer type (*const or *) for a given field accessor
pub fn STAccessorPointerType(comptime T: anytype, comptime field: anytype) type {
    const field_name = @tagName(field);
    const BaseType = STBaseType(T, field);

    return if (std.mem.endsWith(u8, field_name, "_prime") or
        std.mem.endsWith(u8, field_name, "_dagger") or
        std.mem.endsWith(u8, field_name, "_double_dagger"))
        *BaseType
    else
        *const BaseType;
}

// Generates all field variants (base + prime).
// Unused variants are optimized out by the compiler.
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
