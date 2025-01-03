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
        beta_dagger: ?state.Beta = null, // β†
        delta_double_dagger: ?state.Delta = null, // δ‡
        rho_dagger: ?state.Rho(params.core_count) = null, // ρ†
        rho_double_dagger: ?state.Rho(params.core_count) = null, // ρ‡

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

        /// Ensure a field is available for transition. Returns an error if field
        /// cannot be transitioned to the requested state.
        pub fn ensure(self: *Self, comptime field: STAccessors(State)) Error!*STAccessorType(State, field) {
            const name = @tagName(field);

            // Handle intermediate states
            if (comptime std.mem.eql(u8, name, "beta_dagger")) {
                if (self.prime.beta == null) return Error.PreviousStateRequired;
                if (self.beta_dagger == null) {
                    self.beta_dagger = try self.prime.beta.?.deepClone(self.allocator);
                }
                return &self.beta_dagger.?;
            }

            if (comptime std.mem.eql(u8, name, "delta_double_dagger")) {
                if (self.prime.delta == null) return Error.PreviousStateRequired;
                if (self.delta_double_dagger == null) {
                    self.delta_double_dagger = try self.prime.delta.?.deepClone(self.allocator);
                }
                return &self.delta_double_dagger.?;
            }

            if (comptime std.mem.eql(u8, name, "rho_dagger")) {
                if (self.rho_double_dagger != null) return Error.StateTransitioned;
                if (self.prime.rho == null) return Error.PreviousStateRequired;
                if (self.rho_dagger == null) {
                    self.rho_dagger = try self.prime.rho.?.deepClone(self.allocator);
                }
                return &self.rho_dagger.?;
            }

            if (comptime std.mem.eql(u8, name, "rho_double_dagger")) {
                if (self.rho_dagger == null) return Error.PreviousStateRequired;
                if (self.rho_double_dagger == null) {
                    self.rho_double_dagger = try self.rho_dagger.?.deepClone(self.allocator);
                }
                return &self.rho_double_dagger.?;
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
                // Prime state requested
                if (prime_field.* == null) {
                    switch (@typeInfo(@TypeOf(base_field.*.?))) {
                        .@"struct", .@"union" => {
                            // Check if type has deepClone method
                            if (@hasDecl(@TypeOf(base_field.*.?), "deepClone")) {
                                // Check if deepClone takes allocator
                                const info = @typeInfo(@TypeOf(@TypeOf(base_field.*.?).deepClone));
                                prime_field.* = if (info == .@"fn" and info.@"fn".params.len > 1 and
                                    info.@"fn".params[1].type == std.mem.Allocator)
                                    try base_field.*.?.deepClone(self.allocator)
                                else
                                    try base_field.*.?.deepClone();
                            } else {
                                // No deepClone, do simple copy
                                @compileError("All structs / unions must have a deepClone method");
                            }
                        },
                        else => {
                            prime_field.* = base_field.*.?;
                        }, // Simple types get copied directly
                    }
                }
                return &prime_field.*.?;
            } else {
                // Base state requested
                // TODO: this is a concession maybe redesign soe we can get const type as well
                return @constCast(&base_field.*.?);
            }
        }

        /// Initialize a field with a value. Only works for prime and dagger states.
        /// Returns error if field is already initialized or if trying to initialize a base field.
        pub fn initialize(self: *Self, comptime field: STAccessors(State), value: STAccessorType(State, field)) Error!void {
            const name = @tagName(field);

            // Ensure we're only initializing prime or dagger states
            if (!std.mem.endsWith(u8, name, "_prime") and
                !std.mem.endsWith(u8, name, "_dagger") and
                !std.mem.endsWith(u8, name, "_double_dagger"))
            {
                return Error.StateTransitioned;
            }

            // Special handling for dagger states
            if (comptime std.mem.eql(u8, name, "beta_dagger")) {
                if (self.beta_dagger != null) return Error.StateTransitioned;
                self.beta_dagger = value;
                return;
            }
            if (comptime std.mem.eql(u8, name, "delta_double_dagger")) {
                if (self.delta_double_dagger != null) return Error.StateTransitioned;
                self.delta_double_dagger = value;
                return;
            }
            if (comptime std.mem.eql(u8, name, "rho_dagger")) {
                if (self.rho_dagger != null) return Error.StateTransitioned;
                self.rho_dagger = value;
                return;
            }
            if (comptime std.mem.eql(u8, name, "rho_double_dagger")) {
                if (self.rho_double_dagger != null) return Error.StateTransitioned;
                self.rho_double_dagger = value;
                return;
            }

            // Handle prime state initialization
            const base_name = name[0 .. name.len - 6];
            const prime_field = &@field(self.prime, base_name);

            if (prime_field.* != null) return Error.StateTransitioned;
            prime_field.* = value;
        }

        /// Overwrite a field's value. The field must already be initialized.
        /// Returns error if the field is not initialized yet.
        pub fn overwrite(self: *Self, comptime field: STAccessors(State), value: STAccessorType(State, field)) Error!void {
            const name = @tagName(field);

            // Special handling for dagger states
            if (comptime std.mem.eql(u8, name, "beta_dagger")) {
                if (self.beta_dagger == null) return Error.PreviousStateRequired;
                self.beta_dagger = value;
                return;
            }
            if (comptime std.mem.eql(u8, name, "delta_double_dagger")) {
                if (self.delta_double_dagger == null) return Error.PreviousStateRequired;
                self.delta_double_dagger = value;
                return;
            }
            if (comptime std.mem.eql(u8, name, "rho_dagger")) {
                if (self.rho_dagger == null) return Error.PreviousStateRequired;
                self.rho_dagger = value;
                return;
            }
            if (comptime std.mem.eql(u8, name, "rho_double_dagger")) {
                if (self.rho_double_dagger == null) return Error.PreviousStateRequired;
                self.rho_double_dagger = value;
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

        /// Free all transition state resources
        pub fn deinit(self: *Self) void {
            self.prime.deinit(self.allocator);
            if (self.beta_dagger) |*beta| beta.deinit();
            if (self.delta_double_dagger) |*delta| delta.deinit();
            if (self.rho_dagger) |*rho| rho.deinit();
            if (self.rho_double_dagger) |*rho| rho.deinit();
            if (self.accumulation_commitment) |*c| c.deinit();
        }
    };
}

/// Returns the type of a field accessor for a given state and field name.
/// Handles both base fields and special transition states (dagger/double_dagger).
pub fn STAccessorType(comptime T: anytype, comptime field: anytype) type {
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
