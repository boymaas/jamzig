const std = @import("std");
const jamstate = @import("state.zig");
const types = @import("types.zig");
const Params = @import("jam_params.zig").Params;

pub const StateComplexity = enum {
    minimal,    // Only required fields populated
    moderate,   // Some optional components populated
    maximal,    // All components at reasonable limits
};

pub const RandomStateGenerator = struct {
    allocator: std.mem.Allocator,
    rng: std.Random,

    pub fn init(allocator: std.mem.Allocator, rng: std.Random) RandomStateGenerator {
        return RandomStateGenerator{
            .allocator = allocator,
            .rng = rng,
        };
    }

    /// Generate a random JamState with specified complexity
    pub fn generateRandomState(
        self: *RandomStateGenerator,
        comptime params: Params,
        complexity: StateComplexity,
    ) !jamstate.JamState(params) {
        var state = try jamstate.JamState(params).init(self.allocator);

        switch (complexity) {
            .minimal => {
                // Initialize only the most basic required components
                try self.generateMinimalState(params, &state);
            },
            .moderate => {
                // Initialize basic components plus some optional ones
                try self.generateMinimalState(params, &state);
                try self.generateModerateState(params, &state);
            },
            .maximal => {
                // Initialize all components with realistic data
                try self.generateMinimalState(params, &state);
                try self.generateModerateState(params, &state);
                try self.generateMaximalState(params, &state);
            },
        }

        return state;
    }

    /// Generate basic required state components
    fn generateMinimalState(
        self: *RandomStateGenerator,
        comptime params: Params,
        state: *jamstate.JamState(params),
    ) !void {
        // Initialize basic time component (tau)
        try state.initTau();
        state.tau = self.rng.int(types.TimeSlot);

        // Initialize basic entropy (eta)
        try state.initEta();
        for (&state.eta.?) |*entropy| {
            self.rng.bytes(entropy);
        }
    }

    /// Generate moderate complexity state components
    fn generateModerateState(
        self: *RandomStateGenerator,
        comptime params: Params,
        state: *jamstate.JamState(params),
    ) !void {
        // Initialize authorization pool (alpha)
        try state.initAlpha(self.allocator);
        try self.generateRandomAlpha(params, &state.alpha.?);

        // Initialize recent blocks (beta)
        try state.initBeta(self.allocator);
        try self.generateRandomBeta(params, &state.beta.?);

        // Initialize service accounts (delta)
        try state.initDelta(self.allocator);
        try self.generateRandomDelta(params, &state.delta.?);
    }

    /// Generate maximal complexity state components
    fn generateMaximalState(
        self: *RandomStateGenerator,
        comptime params: Params,
        state: *jamstate.JamState(params),
    ) !void {
        // Initialize all remaining components
        try state.initGamma(self.allocator);
        try self.generateRandomGamma(params, &state.gamma.?);

        try state.initPhi(self.allocator);
        try self.generateRandomPhi(params, &state.phi.?);

        try state.initChi(self.allocator);
        try self.generateRandomChi(params, &state.chi.?);

        try state.initPsi(self.allocator);
        try self.generateRandomPsi(params, &state.psi.?);

        try state.initPi(self.allocator);
        try self.generateRandomPi(params, &state.pi.?);

        try state.initXi(self.allocator);
        try self.generateRandomXi(params, &state.xi.?);

        try state.initTheta(self.allocator);
        try self.generateRandomTheta(params, &state.theta.?);

        try state.initRho(self.allocator);
        try self.generateRandomRho(params, &state.rho.?);

        // Initialize validator sets
        state.iota = try types.ValidatorSet.init(self.allocator, params.validators_count);
        try self.generateRandomValidatorSet(&state.iota.?);

        state.kappa = try types.ValidatorSet.init(self.allocator, params.validators_count);
        try self.generateRandomValidatorSet(&state.kappa.?);

        state.lambda = try types.ValidatorSet.init(self.allocator, params.validators_count);
        try self.generateRandomValidatorSet(&state.lambda.?);
    }

    /// Generate random authorization pool data
    fn generateRandomAlpha(
        self: *RandomStateGenerator,
        comptime params: Params,
        alpha: *jamstate.Alpha(params.core_count, params.max_authorizations_pool_items),
    ) !void {
        // Generate random authorizations for each core
        for (0..params.core_count) |core| {
            const pool_size = self.rng.uintAtMost(u8, params.max_authorizations_pool_items);
            for (0..pool_size) |_| {
                var auth_hash: [32]u8 = undefined;
                self.rng.bytes(&auth_hash);
                alpha.pools[core].append(auth_hash) catch break; // Stop if pool is full
            }
        }
    }

    /// Generate random recent blocks data
    fn generateRandomBeta(
        _: *RandomStateGenerator,
        comptime _: Params,
        _: *jamstate.Beta,
    ) !void {
        // TODO: Implement proper block creation once Beta structure is analyzed
    }

    /// Generate random service accounts data
    fn generateRandomDelta(
        _: *RandomStateGenerator,
        comptime _: Params,
        _: *jamstate.Delta,
    ) !void {
        // TODO: Implement proper service account creation once Delta structure is analyzed
    }

    /// Generate random gamma (safrole state) data
    fn generateRandomGamma(
        _: *RandomStateGenerator,
        comptime params: Params,
        _: *jamstate.Gamma(params.validators_count, params.epoch_length),
    ) !void {
        // TODO: Implement once Gamma structure is analyzed
    }

    /// Generate random phi (authorization queue) data
    fn generateRandomPhi(
        _: *RandomStateGenerator,
        comptime params: Params,
        _: *jamstate.Phi(params.core_count, params.max_authorizations_queue_items),
    ) !void {
        // TODO: Implement once Phi structure is analyzed
    }

    /// Generate random chi (privileged services) data
    fn generateRandomChi(
        _: *RandomStateGenerator,
        comptime _: Params,
        _: *jamstate.Chi,
    ) !void {
        // TODO: Implement once Chi structure is analyzed
    }

    /// Generate random psi (disputes) data
    fn generateRandomPsi(
        _: *RandomStateGenerator,
        comptime _: Params,
        _: *jamstate.Psi,
    ) !void {
        // TODO: Implement once Psi structure is analyzed
    }

    /// Generate random pi (validator stats) data
    fn generateRandomPi(
        self: *RandomStateGenerator,
        comptime _: Params,
        pi: *jamstate.Pi,
    ) !void {
        // Generate random validator stats for current epoch
        for (pi.current_epoch_stats.items) |*validator_stats| {
            validator_stats.blocks_produced = self.rng.int(u32) % 100;
            validator_stats.tickets_introduced = self.rng.int(u32) % 50;
            validator_stats.preimages_introduced = self.rng.int(u32) % 25;
            validator_stats.octets_across_preimages = self.rng.int(u32) % 10000;
            validator_stats.reports_guaranteed = self.rng.int(u32) % 75;
            validator_stats.availability_assurances = self.rng.int(u32) % 30;
        }

        // Generate random validator stats for previous epoch
        for (pi.previous_epoch_stats.items) |*validator_stats| {
            validator_stats.blocks_produced = self.rng.int(u32) % 100;
            validator_stats.tickets_introduced = self.rng.int(u32) % 50;
            validator_stats.preimages_introduced = self.rng.int(u32) % 25;
            validator_stats.octets_across_preimages = self.rng.int(u32) % 10000;
            validator_stats.reports_guaranteed = self.rng.int(u32) % 75;
            validator_stats.availability_assurances = self.rng.int(u32) % 30;
        }

        // Generate random core activity records
        for (pi.core_stats.items) |*core_record| {
            core_record.da_load = self.rng.int(u32) % 1000;
            core_record.popularity = self.rng.int(u16) % 500;
            core_record.imports = self.rng.int(u16) % 200;
            core_record.exports = self.rng.int(u16) % 200;
            core_record.extrinsic_count = self.rng.int(u16) % 100;
            core_record.extrinsic_size = self.rng.int(u32) % 50000;
            core_record.bundle_size = self.rng.int(u32) % 100000;
            core_record.gas_used = self.rng.int(u64) % 1000000;
        }

        // Optionally add some random service stats
        const num_services = self.rng.int(u8) % 5; // 0-4 services
        var i: u8 = 0;
        while (i < num_services) : (i += 1) {
            const service_id = self.rng.int(u32);
            const service_record = @import("validator_stats.zig").ServiceActivityRecord{
                .provided_count = self.rng.int(u16) % 100,
                .provided_size = self.rng.int(u32) % 10000,
                .refinement_count = self.rng.int(u32) % 50,
                .refinement_gas_used = self.rng.int(u64) % 500000,
                .accumulate_count = self.rng.int(u32) % 25,
                .accumulate_gas_used = self.rng.int(u64) % 250000,
                .imports = self.rng.int(u32) % 5000,
                .exports = self.rng.int(u32) % 5000,
                .extrinsic_count = self.rng.int(u32) % 25,
                .extrinsic_size = self.rng.int(u32) % 2500,
                .on_transfers_count = self.rng.int(u32) % 10,
                .on_transfers_gas_used = self.rng.int(u64) % 100000,
            };
            try pi.service_stats.put(service_id, service_record);
        }
    }

    /// Generate random xi (accumulated reports) data
    fn generateRandomXi(
        _: *RandomStateGenerator,
        comptime params: Params,
        _: *jamstate.Xi(params.epoch_length),
    ) !void {
        // TODO: Implement once Xi structure is analyzed
    }

    /// Generate random theta (reports ready) data
    fn generateRandomTheta(
        _: *RandomStateGenerator,
        comptime params: Params,
        _: *jamstate.Theta(params.epoch_length),
    ) !void {
        // TODO: Implement once Theta structure is analyzed
    }

    /// Generate random rho (pending reports) data
    fn generateRandomRho(
        _: *RandomStateGenerator,
        comptime params: Params,
        _: *jamstate.Rho(params.core_count),
    ) !void {
        // TODO: Implement once Rho structure is analyzed
    }

    /// Generate random validator set data
    fn generateRandomValidatorSet(
        _: *RandomStateGenerator,
        _: *types.ValidatorSet,
    ) !void {
        // TODO: Implement once ValidatorSet structure is analyzed
    }

    /// Helper function to generate a random hash
    fn generateRandomHash(self: *RandomStateGenerator) [32]u8 {
        var hash: [32]u8 = undefined;
        self.rng.bytes(&hash);
        return hash;
    }
};

test "random_state_generator_minimal" {
    const allocator = std.testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;
    
    var prng = std.Random.DefaultPrng.init(42);
    var generator = RandomStateGenerator.init(allocator, prng.random());
    
    var state = try generator.generateRandomState(TINY, .minimal);
    defer state.deinit(allocator);
    
    // Verify basic components are initialized
    try std.testing.expect(state.tau != null);
    try std.testing.expect(state.eta != null);
}

test "random_state_generator_moderate" {
    const allocator = std.testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;
    
    var prng = std.Random.DefaultPrng.init(123);
    var generator = RandomStateGenerator.init(allocator, prng.random());
    
    var state = try generator.generateRandomState(TINY, .moderate);
    defer state.deinit(allocator);
    
    // Verify moderate components are initialized
    try std.testing.expect(state.tau != null);
    try std.testing.expect(state.eta != null);
    try std.testing.expect(state.alpha != null);
    try std.testing.expect(state.beta != null);
    try std.testing.expect(state.delta != null);
}

test "random_state_generator_maximal" {
    const allocator = std.testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;
    
    var prng = std.Random.DefaultPrng.init(456);
    var generator = RandomStateGenerator.init(allocator, prng.random());
    
    var state = try generator.generateRandomState(TINY, .maximal);
    defer state.deinit(allocator);
    
    // Verify all components are initialized
    try std.testing.expect(state.tau != null);
    try std.testing.expect(state.eta != null);
    try std.testing.expect(state.alpha != null);
    try std.testing.expect(state.beta != null);
    try std.testing.expect(state.gamma != null);
    try std.testing.expect(state.delta != null);
    try std.testing.expect(state.phi != null);
    try std.testing.expect(state.chi != null);
    try std.testing.expect(state.psi != null);
    try std.testing.expect(state.pi != null);
    try std.testing.expect(state.xi != null);
    try std.testing.expect(state.theta != null);
    try std.testing.expect(state.rho != null);
    try std.testing.expect(state.iota != null);
    try std.testing.expect(state.kappa != null);
    try std.testing.expect(state.lambda != null);
}