const std = @import("std");
const types = @import("types.zig");

const Params = @import("jam_params.zig").Params;

/// This struct represents the full state (`σ`) of the Jam protocol.
/// It contains segments for core consensus, validator management, service
/// state, and protocol-level metadata. Each component of the state represents
/// a specific functional segment, allowing partitioned state management.
pub fn JamState(comptime params: Params) type {
    return struct {
        /// α: Core authorization state and associated queues.
        /// Manipulated in: src/authorization.zig
        alpha: ?Alpha(params.core_count, params.max_authorizations_pool_items) = null,

        /// β: Metadata of the latest block, including block number, timestamps, and cryptographic references.
        /// Manipulated in: src/recent_blocks.zig
        beta: ?Beta = null,

        /// γ: List of current validators and their states, such as stakes and identities.
        /// Manipulated in: src/safrole.zig
        gamma: ?Gamma(params.validators_count, params.epoch_length) = null,

        /// δ: Service accounts state, managing all service-related data (similar to smart contracts).
        /// Manipulated in: src/services.zig
        delta: ?Delta = null,

        /// η: On-chain entropy pool used for randomization and consensus mechanisms.
        /// Manipulated in: src/safrole.zig
        eta: ?Eta = null,

        /// ι: Validators enqueued for activation in the upcoming epoch.
        /// Manipulated in: src/safrole.zig
        iota: ?Iota = null,

        /// κ: Active validator set currently responsible for validating blocks and maintaining the network.
        /// Manipulated in: src/safrole.zig
        kappa: ?Kappa = null,

        /// λ: Archived validators who have been removed or rotated out of the active set.
        /// Manipulated in: src/safrole.zig
        lambda: ?Lambda = null,

        /// ρ: State related to each core’s current assignment, including work packages and reports.
        /// Manipulated in: src/core_assignments.zig
        rho: ?Rho(params.core_count) = null,

        /// τ: Current time, represented in terms of epochs and slots.
        /// Manipulated in: src/safrole.zig
        tau: ?Tau = null,

        /// φ: Authorization queue for tasks or processes awaiting authorization by the network.
        /// Manipulated in: src/authorization.zig
        phi: ?Phi(params.core_count, params.max_authorizations_queue_items) = null,

        /// χ: Privileged service identities, which may have special roles within the protocol.
        /// Manipulated in: src/services.zig
        chi: ?Chi = null,

        /// ψ: Judgement state, tracking disputes or reports about validators or state transitions.
        /// Manipulated in: src/disputes.zig
        psi: ?Psi = null,

        /// π: Validator performance statistics, tracking penalties, rewards, and other metrics.
        /// Manipulated in: src/validator_stats.zig
        pi: ?Pi = null,

        /// ξ: Epochs worth history of accumulated work reports
        xi: ?Xi(params.epoch_length) = null,

        /// θ: List of available and/or audited but not yet accumulated work
        /// reports
        theta: ?Theta(params.epoch_length) = null,

        /// Initialize Alpha component
        pub fn initAlpha(self: *JamState(params), _: std.mem.Allocator) !void {
            self.alpha = Alpha(params.core_count, params.max_authorizations_pool_items).init();
        }

        /// Initialize Beta component (max_blocks should be 10)
        /// TODO: check if this max_blocks is in the params
        pub fn initBeta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.beta = try Beta.init(allocator, params.recent_history_size);
        }

        /// Initialize Gamma component
        pub fn initGamma(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.gamma = try Gamma(params.validators_count, params.epoch_length).init(allocator);
        }

        /// Initialize Delta component
        pub fn initDelta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.delta = Delta.init(allocator);
        }

        /// Initialize Phi component
        pub fn initPhi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.phi = try Phi(params.core_count, params.max_authorizations_queue_items).init(allocator);
        }

        /// Initialize Chi component
        pub fn initChi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.chi = Chi.init(allocator);
        }

        /// Initialize Psi component
        pub fn initPsi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.psi = Psi.init(allocator);
        }

        /// Initialize Pi component
        pub fn initPi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.pi = try Pi.init(allocator, params.validators_count);
        }

        /// Initialize Xi component
        pub fn initXi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.xi = Xi(params.epoch_length).init(allocator);
        }

        /// Initialize Rho component
        pub fn initRho(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.rho = Rho(params.core_count).init(allocator);
        }

        /// Initialize Theta component
        pub fn initTheta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.theta = Theta(params.epoch_length).init(allocator);
        }

        /// Initialize Eta component
        pub fn initEta(self: *JamState(params)) !void {
            // TODO: std.mem.zeroes
            self.eta = [_]types.Entropy{[_]u8{0} ** 32} ** 4;
        }

        /// Initialize Tau component
        pub fn initTau(self: *JamState(params)) !void {
            self.tau = 0;
        }

        /// Initialize all components necessary for Safrole operation
        /// This includes: gamma, eta, iota, kappa, lambda, and tau
        pub fn initSafrole(self: *JamState(params), allocator: std.mem.Allocator) !void {
            // Initialize required components
            try self.initEta();
            try self.initTau();

            try self.initGamma(allocator);
            self.iota = try types.ValidatorSet.init(allocator, params.validators_count);
            self.kappa = try types.ValidatorSet.init(allocator, params.validators_count);
            self.lambda = try types.ValidatorSet.init(allocator, params.validators_count);
        }

        /// Initialize a new JamState
        pub fn init(
            // TODO: maybe remove parameter
            _: std.mem.Allocator,
        ) !JamState(params) {
            return JamState(params){};
        }

        /// Initialize an empty genesis state with all components properly initialized
        pub fn initGenesis(allocator: std.mem.Allocator) !JamState(params) {
            var state = try JamState(params).init(allocator);

            try state.initAlpha(allocator);
            try state.initBeta(allocator);
            try state.initChi(allocator);
            try state.initDelta(allocator);
            try state.initPhi(allocator);
            try state.initPsi(allocator);
            try state.initPi(allocator);
            try state.initXi(allocator);
            try state.initTheta(allocator);
            try state.initRho(allocator);

            // NOTE: Eta and Tau are initialized in Safrole
            // try state.initEta();
            // try state.initTau();
            try state.initSafrole(allocator);

            return state;
        }

        const state_dict = @import("state_dictionary.zig");
        pub fn buildStateMerklizationDictionary(self: *const JamState(params), allocator: std.mem.Allocator) !state_dict.MerklizationDictionary {
            return try state_dict.buildStateMerklizationDictionary(params, allocator, self);
        }
        pub fn buildStateMerklizationDictionaryWithConfig(self: *const JamState(params), allocator: std.mem.Allocator, comptime config: state_dict.DictionaryConfig) !state_dict.MerklizationDictionary {
            return try state_dict.buildStateMerklizationDictionaryWithConfig(params, allocator, self, config);
        }

        pub fn buildStateRoot(self: *const JamState(params), allocator: std.mem.Allocator) !types.StateRoot {
            var map = try self.buildStateMerklizationDictionary(allocator);
            defer map.deinit();
            return try @import("state_merklization.zig").merklizeStateDictionary(allocator, &map);
        }

        pub fn buildStateRootWithConfig(self: *const JamState(params), allocator: std.mem.Allocator, comptime config: state_dict.DictionaryConfig) !types.StateRoot {
            var map = try self.buildStateMerklizationDictionaryWithConfig(allocator, config);
            defer map.deinit();
            return try @import("state_merklization.zig").merklizeStateDictionary(allocator, &map);
        }

        // Comptime patterns
        usingnamespace StateHelpers;

        pub fn checkIfFullyInitialized(self: *const JamState(params)) !bool {
            // Define our error type at compile time
            const InitError = comptime StateHelpers.buildInitErrorType(@TypeOf(self.*));

            // Check each field using inline for
            inline for (std.meta.fields(@TypeOf(self.*))) |field| {
                if (@field(self, field.name) == null) {
                    return @field(InitError, "Uninitialized" ++ StateHelpers.capitalize(field.name));
                }
            }
            return true;
        }

        pub fn deepClone(self: *const JamState(params), allocator: std.mem.Allocator) !JamState(params) {
            var clone = JamState(params){};
            inline for (std.meta.fields(JamState(params))) |field| {
                @field(clone, field.name) = try self.cloneField(&field, allocator);
            }
            return clone;
        }

        /// Destructively merges `other` state into this one.
        /// Non-null fields from `other` override corresponding fields here.
        /// NOTE: Performs a simple state merge operation for Milestone 1.
        /// Future versions will implement optimized merge strategies.
        pub fn merge(
            self: *JamState(params),
            other: *JamState(params),
            allocator: std.mem.Allocator,
        ) !void {
            inline for (std.meta.fields(@This())) |field| {
                try self.mergeField(other, &field, allocator);
            }
        }

        /// Deinitialize and free resources
        pub fn deinit(self: *JamState(params), allocator: std.mem.Allocator) void {
            inline for (std.meta.fields(@This())) |field| {
                self.deinitField(&field, allocator);
            }
            self.* = undefined;
        }

        /// Format
        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/jam_state.zig").format(params, self, fmt, options, writer);
        }
    };
}

pub fn JamStateView(comptime params: Params) type {
    return struct {
        const Self = @This();

        alpha: ?*const Alpha(params.core_count, params.max_authorizations_pool_items) = null,
        beta: ?*const Beta = null,
        gamma: ?*const Gamma(params.validators_count, params.epoch_length) = null,
        delta: ?*const Delta = null,
        eta: ?*const Eta = null,
        iota: ?*const Iota = null,
        kappa: ?*const Kappa = null,
        lambda: ?*const Lambda = null,
        rho: ?*const Rho(params.core_count) = null,
        tau: ?*const Tau = null,
        phi: ?*const Phi(params.core_count, params.max_authorizations_queue_items) = null,
        chi: ?*const Chi = null,
        psi: ?*const Psi = null,
        pi: ?*const Pi = null,
        xi: ?*const Xi(params.epoch_length) = null,
        theta: ?*const Theta(params.epoch_length) = null,

        pub fn init() Self {
            return Self{};
        }
    };
}

pub const Alpha = @import("authorization.zig").Alpha;
pub const Beta = @import("recent_blocks.zig").RecentHistory;

// History and Queuing or work reports
pub const Xi = @import("accumulated_reports.zig").Xi;
pub const Theta = @import("available_reports.zig").Theta;

// TODO: move this to a seperate file
pub const Gamma = @import("safrole_state.zig").Gamma;
pub const Delta = @import("services.zig").Delta;
pub const Eta = types.Eta;
pub const Iota = types.Iota;
pub const Kappa = types.Kappa;
pub const Lambda = types.Lambda;
pub const Rho = @import("pending_reports.zig").Rho;
pub const Tau = types.TimeSlot;
pub const Phi = @import("authorization_queue.zig").Phi;
pub const Chi = @import("services_priviledged.zig").Chi;
pub const Psi = @import("disputes.zig").Psi;
pub const Pi = @import("validator_stats.zig").Pi;

// Helpers to init decoupled state object by params
pub const init = @import("state_params_init.zig");

// Helper functions that will be used by our comptime methods
const StateHelpers = struct {
    // Helper for merging a single field
    fn mergeField(self: anytype, other: anytype, struct_field: *const std.builtin.Type.StructField, allocator: std.mem.Allocator) !void {
        const field = @field(other, struct_field.name);
        if (field) |other_value| {
            // If the other state has this field
            if (@field(self, struct_field.name)) |*self_value| {
                // Clean up our existing value if needed
                callDeinit(self_value, allocator);
            }
            // Transfer ownership
            @field(self, struct_field.name) = other_value;
            @field(other, struct_field.name) = null;
        }
    }

    // Helper for deep cloning a single field
    fn cloneField(self: anytype, struct_field: *const std.builtin.Type.StructField, allocator: std.mem.Allocator) !std.meta.Child(struct_field.type) {
        const field_type = std.meta.Child(struct_field.type);

        if (comptime isComplexType(field_type)) {
            if (@field(self, struct_field.name)) |value| {
                if (@hasDecl(field_type, "deepClone")) {
                    const info = @typeInfo(@TypeOf(field_type.deepClone));
                    if (info == .@"fn" and info.@"fn".params.len > 1) {
                        return try value.deepClone(allocator);
                    } else {
                        return try value.deepClone();
                    }
                } else {
                    @panic("Please implement deepClone for: " ++ @typeName(field_type));
                }
            }
        } else {
            // For simple types that can be copied directly
            if (@field(self, struct_field.name)) |value| {
                return value;
            }
        }
        unreachable;
    }

    // Helper for deinitializing a single field
    fn deinitField(self: anytype, struct_field: *const std.builtin.Type.StructField, allocator: std.mem.Allocator) void {
        var field = @field(self, struct_field.name);
        if (field) |*value| {
            callDeinit(value, allocator);
        }
    }

    // Helper function to check if a type is a struct or union
    fn isComplexType(comptime T: type) bool {
        const type_info = @typeInfo(T);
        return type_info == .@"struct" or type_info == .@"union";
    }

    fn callDeinit(value: anytype, allocator: std.mem.Allocator) void {
        const ValueType = std.meta.Child(@TypeOf(value));

        // return early, as we have nothing to call here
        if (!comptime isComplexType(ValueType)) {
            return;
        }

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

    fn capitalize(comptime str: []const u8) [str.len]u8 {
        comptime {
            var buffer: [str.len]u8 = undefined;
            buffer[0] = std.ascii.toUpper(str[0]);
            std.mem.copyForwards(u8, buffer[1..], str[1..]);
            return buffer;
        }
    }

    /// Checks if the whole state has been initialized. We do not have any
    /// entries which are null
    ///
    // Helper function to build the InitError type at compile time
    fn buildInitErrorType(comptime T: type) type {
        // Get all fields of the state struct
        const fields = std.meta.fields(T);

        // Create a tuple type containing all our error tags
        var error_fields: [fields.len]std.builtin.Type.Error = undefined;
        for (fields, 0..) |field, i| {
            error_fields[i] = .{
                .name = "Uninitialized" ++ capitalize(field.name),
            };
        }

        // Create and return the error set type
        return @Type(.{ .error_set = &error_fields });
    }
};
