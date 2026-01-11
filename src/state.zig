const std = @import("std");
const types = @import("types.zig");

const Params = @import("jam_params.zig").Params;

/// This struct represents the full state (`σ`) of the Jam protocol.
/// It contains segments for core consensus, validator management, service
/// state, and protocol-level metadata. Each component of the state represents
/// a specific functional segment, allowing partitioned state management.
pub fn JamState(comptime params: Params) type {
    return struct {
        /// α - src/authorization.zig
        alpha: ?Alpha(params.core_count, params.max_authorizations_pool_items) = null,

        /// β - src/recent_blocks.zig
        beta: ?Beta = null,

        /// γ - src/safrole.zig
        gamma: ?Gamma(params.validators_count, params.epoch_length) = null,

        /// δ - src/services.zig
        delta: ?Delta = null,

        /// η - src/safrole.zig
        eta: ?Eta = null,

        /// ι - src/safrole.zig
        iota: ?Iota = null,

        /// κ - src/safrole.zig
        kappa: ?Kappa = null,

        /// λ - src/safrole.zig
        lambda: ?Lambda = null,

        /// ρ - src/core_assignments.zig
        rho: ?Rho(params.core_count) = null,

        /// τ - src/safrole.zig
        tau: ?Tau = null,

        /// φ - src/authorization.zig
        phi: ?Phi(params.core_count, params.max_authorizations_queue_items) = null,

        /// χ - src/services.zig
        chi: ?Chi(params.core_count) = null,

        /// ψ - src/disputes.zig
        psi: ?Psi = null,

        /// π - src/validator_stats.zig
        pi: ?Pi = null,

        /// ξ - History of accumulated work reports
        xi: ?Xi(params.epoch_length) = null,

        /// ϑ (vartheta) - Work reports ready for accumulation (v0.6.7: renamed from theta)
        vartheta: ?VarTheta(params.epoch_length) = null,

        /// θ (theta) - Most recent accumulation outputs (v0.6.7: new component)
        theta: ?Theta = null,

        /// ancestry - Historical block headers for lookup-anchor validation
        ancestry: ?Ancestry = null,

        pub fn initAlpha(self: *JamState(params), _: std.mem.Allocator) !void {
            self.alpha = Alpha(params.core_count, params.max_authorizations_pool_items).init();
        }

        /// TODO: check if this max_blocks is in the params
        pub fn initBeta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.beta = try Beta.init(allocator, params.recent_history_size);
        }

        pub fn initGamma(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.gamma = try Gamma(params.validators_count, params.epoch_length).init(allocator);
        }

        pub fn initDelta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.delta = Delta.init(allocator);
        }

        pub fn initPhi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.phi = try Phi(params.core_count, params.max_authorizations_queue_items).init(allocator);
        }

        pub fn initChi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.chi = try Chi(params.core_count).init(allocator);
        }

        pub fn initPsi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.psi = Psi.init(allocator);
        }

        pub fn initPi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.pi = try Pi.init(allocator, params.validators_count, params.core_count);
        }

        pub fn initXi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.xi = Xi(params.epoch_length).init(allocator);
        }

        pub fn initRho(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.rho = Rho(params.core_count).init(allocator);
        }

        pub fn initVartheta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.vartheta = VarTheta(params.epoch_length).init(allocator);
        }

        pub fn initTheta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.theta = Theta.init(allocator);
        }

        pub fn initAncestry(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.ancestry = Ancestry.init(allocator);
        }

        pub fn initEta(self: *JamState(params)) !void {
            // TODO: std.mem.zeroes
            self.eta = [_]types.Entropy{[_]u8{0} ** 32} ** 4;
        }

        pub fn initTau(self: *JamState(params)) !void {
            self.tau = 0;
        }

        pub fn initSafrole(self: *JamState(params), allocator: std.mem.Allocator) !void {
            // Initialize required components
            try self.initEta();
            try self.initTau();

            try self.initGamma(allocator);
            self.iota = try types.ValidatorSet.init(allocator, params.validators_count);
            self.kappa = try types.ValidatorSet.init(allocator, params.validators_count);
            self.lambda = try types.ValidatorSet.init(allocator, params.validators_count);
        }

        pub fn init(
            // TODO: maybe remove parameter
            _: std.mem.Allocator,
        ) !JamState(params) {
            return JamState(params){};
        }

        pub fn initGenesis(allocator: std.mem.Allocator) !JamState(params) {
            return initGenesisWithOptions(allocator, .{ .enable_ancestry = true });
        }

        pub const InitOptions = struct {
            enable_ancestry: bool = true,
        };

        pub fn initGenesisWithOptions(allocator: std.mem.Allocator, options: InitOptions) !JamState(params) {
            var state = try JamState(params).init(allocator);

            try state.initAlpha(allocator);
            try state.initPhi(allocator);

            try state.initBeta(allocator);
            try state.initChi(allocator);
            try state.initDelta(allocator);
            try state.initPsi(allocator);
            try state.initPi(allocator);
            try state.initXi(allocator);
            try state.initVartheta(allocator);
            try state.initTheta(allocator);
            try state.initRho(allocator);

            // NOTE: Eta and Tau are initialized in Safrole
            // try state.initEta();
            // try state.initTau();
            try state.initSafrole(allocator);

            // Auxiliary state - only initialize if enabled
            if (options.enable_ancestry) {
                try state.initAncestry(allocator);
            }

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

            const auxiliary_fields = [_][]const u8{"ancestry"};

            inline for (std.meta.fields(@TypeOf(self.*))) |field| {

                // Only check non-auxiliary fields
                const is_aux_field = for (auxiliary_fields) |aux_field| {
                    if (std.mem.eql(u8, aux_field, field.name)) break true;
                } else false;

                // Skip auxiliary fields (ancestry is optional auxiliary data)
                if (!is_aux_field) {
                    if (@field(self, field.name) == null) {
                        return @field(InitError, "Uninitialized" ++ StateHelpers.capitalize(field.name));
                    }
                }
            }
            return true;
        }

        // will be optimized out
        pub fn debugCheckIfFullyInitialized(self: *const JamState(params)) !void {
            if (@import("builtin").mode == .Debug) {
                if (!try self.checkIfFullyInitialized()) {
                    return error.StateNotFullyInitialized;
                }
            }
        }

        pub fn deepClone(self: *const JamState(params), allocator: std.mem.Allocator) !JamState(params) {
            var clone = JamState(params){};
            inline for (std.meta.fields(JamState(params))) |field| {
                if (@field(self, field.name)) |value| {
                    @field(clone, field.name) = try StateHelpers.copyOrDeepCloneValue(value, allocator);
                }
            }
            return clone;
        }

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

        pub fn deinit(self: *JamState(params), allocator: std.mem.Allocator) void {
            inline for (std.meta.fields(@This())) |field| {
                self.deinitField(&field, allocator);
            }
            self.* = undefined;
        }

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const tfmt = @import("types/fmt.zig");
            const formatter = tfmt.Format(@TypeOf(self.*)){
                .value = self.*,
                .options = .{},
            };
            try formatter.format(fmt, options, writer);
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
        vartheta: ?*const VarTheta(params.epoch_length) = null,
        theta: ?*const Theta = null,

        // Auxiliary state
        ancestry: ?*const Ancestry = null,

        pub fn init() Self {
            return Self{};
        }

        pub fn fromJamState(state: *const JamState(params)) @This() {
            var view = @This(){};

            inline for (std.meta.fields(@This())) |*field| {
                if (@field(state, field.name)) |*value| {
                    @field(view, field.name) = value;
                }
            }

            return view;
        }
    };
}

// Core imports
pub const authorizer_pool = @import("authorizer_pool.zig");
pub const beta = @import("beta.zig");
pub const recent_blocks = @import("recent_blocks.zig");
pub const accumulated_reports = @import("reports_accumulated.zig");
pub const reports_ready = @import("reports_ready.zig");
pub const accumulation_outputs = @import("accumulation_outputs.zig");
pub const safrole_state = @import("safrole_state.zig");
pub const services = @import("services.zig");
pub const pending_reports = @import("reports_pending.zig");
pub const authorizer_queue = @import("authorizer_queue.zig");
pub const services_privileged = @import("services_privileged.zig");
pub const disputes = @import("disputes.zig");
pub const validator_stats = @import("validator_stats.zig");
pub const ancestry = @import("ancestry.zig");

// State components
pub const Alpha = authorizer_pool.Alpha;
pub const Beta = beta.Beta; // v0.6.7: Now contains (recent_history, beefy_belt)

// History and Queuing of work reports
pub const Xi = accumulated_reports.Xi;
pub const VarTheta = reports_ready.VarTheta; // v0.6.7: Renamed from Theta to VarTheta
pub const Theta = accumulation_outputs.Theta; // v0.6.7: NEW - accumulation outputs

// Validator and network state
pub const Gamma = safrole_state.Gamma;
pub const Delta = services.Delta;
pub const Eta = types.Eta;
pub const Iota = types.Iota;
pub const Kappa = types.Kappa;
pub const Lambda = types.Lambda;
pub const Rho = pending_reports.Rho;
pub const Tau = types.TimeSlot;
pub const Phi = authorizer_queue.Phi;
pub const Chi = services_privileged.Chi;
pub const Psi = disputes.Psi;
pub const Pi = validator_stats.Pi;
pub const Ancestry = ancestry.Ancestry;

// Helpers to init decoupled state object by params
pub const init = @import("state_params_init.zig");

// Helper functions that will be used by our comptime methods
// TODO: move this into src/meta.zig as these patterns occur more
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
    fn copyOrDeepCloneValue(value: anytype, allocator: std.mem.Allocator) !@TypeOf(value) {
        const T = @TypeOf(value);

        // Check if its a complex type
        if (comptime isComplexType(T)) {
            if (@hasDecl(T, "deepClone")) {
                const info = @typeInfo(@TypeOf(T.deepClone));
                if (info == .@"fn" and info.@"fn".params.len > 1) {
                    return try value.deepClone(allocator);
                } else {
                    return try value.deepClone();
                }
            } else {
                @panic("Please implement deepClone for: " ++ @typeName(T));
            }
        }

        return value;
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

    // TODO: use the meta implementation?
    fn callDeinit(value: anytype, allocator: std.mem.Allocator) void {
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
