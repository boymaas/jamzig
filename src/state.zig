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
        alpha: ?Alpha,

        /// β: Metadata of the latest block, including block number, timestamps, and cryptographic references.
        /// Manipulated in: src/recent_blocks.zig
        beta: ?Beta,

        /// γ: List of current validators and their states, such as stakes and identities.
        /// Manipulated in: src/safrole.zig
        gamma: ?Gamma,

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
        rho: ?Rho,

        /// τ: Current time, represented in terms of epochs and slots.
        /// Manipulated in: src/safrole.zig
        tau: ?Tau,

        /// φ: Authorization queue for tasks or processes awaiting authorization by the network.
        /// Manipulated in: src/authorization.zig
        phi: ?Phi,

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
            self.alpha = try Alpha.init();
        }

        /// Initialize Beta component (max_blocks should be 10)
        /// TODO: check if this max_blocks is in the params
        pub fn initBeta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.beta = try Beta.init(allocator, params.recent_history_size);
        }

        /// Initialize Gamma component
        pub fn initGamma(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.gamma = try Gamma.init(allocator, params.validators_count);
        }

        /// Initialize Delta component
        pub fn initDelta(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.delta = try Delta.init(allocator);
        }

        /// Initialize Phi component
        pub fn initPhi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.phi = try Phi.init(allocator);
        }

        /// Initialize Chi component
        pub fn initChi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.chi = try Chi.init(allocator);
        }

        /// Initialize Psi component
        pub fn initPsi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.psi = try Psi.init(allocator);
        }

        /// Initialize Pi component
        pub fn initPi(self: *JamState(params), allocator: std.mem.Allocator) !void {
            self.pi = try Pi.init(allocator, params.validators_count);
        }

        /// Initialize Xi component
        pub fn initXi(self: *JamState(params), _: std.mem.Allocator) !void {
            self.xi = try Xi(params.epoch_length).init();
        }

        /// Initialize Theta component
        pub fn initTheta(self: *JamState(params), _: std.mem.Allocator) !void {
            self.theta = try Theta(params.epoch_length).init();
        }

        /// Initialize Eta component
        pub fn initEta(self: *JamState(params)) !void {
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
                .alpha = null,
                .beta = null,
                .gamma = null,
                .delta = null,
                .eta = [_]types.Entropy{[_]u8{0} ** 32} ** 4,
                .iota = null,
                .kappa = null,
                .lambda = null,
                .rho = null,
                .tau = 0,
                .phi = null,
                .chi = null,
                .psi = null,
                .pi = null,
                .xi = null,
                .theta = null,
            };
        }

        /// Deinitialize and free resources
        pub fn deinit(self: *JamState(params), allocator: std.mem.Allocator) void {
            if (self.beta) |*beta| beta.deinit(); // TODO: check and make consistent to take allocator
            if (self.delta) |*delta| delta.deinit();
            if (self.gamma) |*gamma| gamma.deinit(allocator);
            if (self.iota) |iota| iota.deinit(allocator);
            if (self.kappa) |kappa| kappa.deinit(allocator);
            if (self.lambda) |lambda| lambda.deinit(allocator);
            if (self.phi) |*phi| phi.deinit();
            if (self.chi) |*chi| chi.deinit();
            if (self.psi) |*psi| psi.deinit();
            if (self.pi) |*pi| pi.deinit();
            if (self.xi) |*xi| xi.deinit();
            if (self.theta) |*theta| theta.deinit();
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

        /// Merge another state into this one
        /// If a field is non-null in the source state, it will override the corresponding field in this state
        pub fn merge(self: *JamState(params), source: JamState(params)) void {
            if (source.alpha) |alpha| self.alpha = alpha;
            if (source.beta) |beta| self.beta = beta;
            if (source.gamma) |gamma| self.gamma = gamma;
            if (source.delta) |delta| self.delta = delta;
            if (source.eta) |eta| self.eta = eta;
            if (source.iota) |iota| self.iota = iota;
            if (source.kappa) |kappa| self.kappa = kappa;
            if (source.lambda) |lambda| self.lambda = lambda;
            if (source.rho) |rho| self.rho = rho;
            if (source.tau) |tau| self.tau = tau;
            if (source.phi) |phi| self.phi = phi;
            if (source.chi) |chi| self.chi = chi;
            if (source.psi) |psi| self.psi = psi;
            if (source.pi) |pi| self.pi = pi;
            if (source.xi) |xi| self.xi = xi;
            if (source.theta) |theta| self.theta = theta;
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
