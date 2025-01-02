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
        alpha: ?Alpha(params.core_count),

        /// β: Metadata of the latest block, including block number, timestamps, and cryptographic references.
        /// Manipulated in: src/recent_blocks.zig
        beta: ?Beta,

        /// γ: List of current validators and their states, such as stakes and identities.
        /// Manipulated in: src/safrole.zig
        gamma: ?Gamma(params.validators_count, params.epoch_length),

        /// δ: Service accounts state, managing all service-related data (similar to smart contracts).
        /// Manipulated in: src/services.zig
        delta: ?Delta,

        /// η: On-chain entropy pool used for randomization and consensus mechanisms.
        /// Manipulated in: src/safrole.zig
        eta: ?Eta,

        /// ι: Validators enqueued for activation in the upcoming epoch.
        /// Manipulated in: src/safrole.zig
        iota: ?Iota,

        /// κ: Active validator set currently responsible for validating blocks and maintaining the network.
        /// Manipulated in: src/safrole.zig
        kappa: ?Kappa,

        /// λ: Archived validators who have been removed or rotated out of the active set.
        /// Manipulated in: src/safrole.zig
        lambda: ?Lambda,

        /// ρ: State related to each core’s current assignment, including work packages and reports.
        /// Manipulated in: src/core_assignments.zig
        rho: ?Rho(params.core_count),

        /// τ: Current time, represented in terms of epochs and slots.
        /// Manipulated in: src/safrole.zig
        tau: ?Tau,

        /// φ: Authorization queue for tasks or processes awaiting authorization by the network.
        /// Manipulated in: src/authorization.zig
        phi: ?Phi(params.core_count, params.max_authorizations_queue_items),

        /// χ: Privileged service identities, which may have special roles within the protocol.
        /// Manipulated in: src/services.zig
        chi: ?Chi,

        /// ψ: Judgement state, tracking disputes or reports about validators or state transitions.
        /// Manipulated in: src/disputes.zig
        psi: ?Psi,

        /// π: Validator performance statistics, tracking penalties, rewards, and other metrics.
        /// Manipulated in: src/validator_stats.zig
        pi: ?Pi,

        /// ξ: Epochs worth history of accumulated work reports
        xi: ?Xi(params.epoch_length),

        /// θ: List of available and/or audited but not yet accumulated work
        /// reports
        theta: ?Theta(params.epoch_length),

        /// Initialize Alpha component
        pub fn initAlpha(self: *JamState(params), _: std.mem.Allocator) !void {
            self.alpha = Alpha(params.core_count).init();
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
            return JamState(params){
                .tau = null,
                .eta = null,
                .alpha = null,
                .beta = null,
                .chi = null,
                .delta = null,
                .gamma = null,
                .iota = null,
                .kappa = null,
                .lambda = null,
                .phi = null,
                .pi = null,
                .psi = null,
                .rho = null,
                .theta = null,
                .xi = null,
            };
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
            try state.initEta();
            try state.initTau();
            try state.initSafrole(allocator);

            return state;
        }

        /// Checks if the whole state has been initialized. We do not have any
        /// entries which are null
        pub fn ensureFullyInitialized(self: *const JamState(params)) !void {
            if (self.alpha == null) return error.UninitializedAlpha;
            if (self.beta == null) return error.UninitializedBeta;
            if (self.gamma == null) return error.UninitializedGamma;
            if (self.delta == null) return error.UninitializedDelta;
            if (self.eta == null) return error.UninitializedEta;
            if (self.iota == null) return error.UninitializedIota;
            if (self.kappa == null) return error.UninitializedKappa;
            if (self.lambda == null) return error.UninitializedLambda;
            if (self.rho == null) return error.UninitializedRho;
            if (self.tau == null) return error.UninitializedTau;
            if (self.phi == null) return error.UninitializedPhi;
            if (self.chi == null) return error.UninitializedChi;
            if (self.psi == null) return error.UninitializedPsi;
            if (self.pi == null) return error.UninitializedPi;
            if (self.xi == null) return error.UninitializedXi;
            if (self.theta == null) return error.UninitializedTheta;
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

        /// Deinitialize and free resources
        pub fn deinit(self: *JamState(params), allocator: std.mem.Allocator) void {
            // NOTE: alpha has no allocations, yet?
            if (self.beta) |*beta| beta.deinit(); // TODO: check and make consistent to take allocator
            if (self.chi) |*chi| chi.deinit();
            if (self.delta) |*delta| delta.deinit();
            if (self.gamma) |*gamma| gamma.deinit(allocator);
            if (self.iota) |iota| iota.deinit(allocator);
            if (self.kappa) |kappa| kappa.deinit(allocator);
            if (self.lambda) |lambda| lambda.deinit(allocator);
            if (self.phi) |*phi| phi.deinit();
            if (self.pi) |*pi| pi.deinit();
            if (self.psi) |*psi| psi.deinit();
            if (self.rho) |*rho| rho.deinit();
            if (self.theta) |*theta| theta.deinit();
            if (self.xi) |*xi| xi.deinit();
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

        /// Destructively merges `other` state into this one.
        /// Non-null fields from `other` override corresponding fields here.
        /// NOTE: `other` becomes invalid after merge.
        /// NOTE: Performs a simple state merge operation for Milestone 1.
        /// Future versions will implement optimized merge strategies.
        pub fn merge(
            self: *JamState(params),
            other: *JamState(params),
            allocator: std.mem.Allocator,
        ) !void {
            if (other.tau) |tau| self.tau = tau;
            if (other.eta) |eta| self.eta = eta;
            // if (source.alpha) |alpha| self.alpha = alpha;
            if (other.beta) |*beta| try self.beta.?.merge(beta);
            // if (source.chi) |chi| self.chi = chi;
            // if (source.delta) |delta| self.delta = delta;
            if (other.gamma) |*gamma|
                self.gamma.?.merge(gamma, allocator);
            if (other.iota) |*iota|
                self.iota.?.merge(iota, allocator);
            if (other.kappa) |*kappa|
                self.kappa.?.merge(kappa, allocator);
            if (other.lambda) |*lambda|
                self.lambda.?.merge(lambda, allocator);
            // if (source.phi) |phi| self.phi = phi;
            // if (source.pi) |pi| self.pi = pi;
            // if (source.psi) |psi| self.psi = psi;
            // if (source.rho) |rho| self.rho = rho;
            // if (source.theta) |theta| self.theta = theta;
            // if (source.xi) |xi| self.xi = xi;
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
