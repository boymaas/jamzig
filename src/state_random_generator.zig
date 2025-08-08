const std = @import("std");
const jamstate = @import("state.zig");
const types = @import("types.zig");
const Params = @import("jam_params.zig").Params;

pub const StateComplexity = enum {
    minimal, // Only required fields populated
    moderate, // Some optional components populated
    maximal, // All components at reasonable limits
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

                // Initialize VarTheta and Rho with minimal complexity
                try state.initVartheta(self.allocator);
                try self.generateRandomTheta(params, .minimal, &state.vartheta.?);

                try state.initRho(self.allocator);
                try self.generateRandomRho(params, .minimal, &state.rho.?);
            },
            .moderate => {
                // Initialize basic components plus some optional ones
                try self.generateMinimalState(params, &state);
                try self.generateModerateState(params, &state);

                // Initialize VarTheta and Rho with moderate complexity (not done in generateModerateState to avoid duplication)
                try state.initVartheta(self.allocator);
                try self.generateRandomTheta(params, .moderate, &state.vartheta.?);

                try state.initRho(self.allocator);
                try self.generateRandomRho(params, .moderate, &state.rho.?);
            },
            .maximal => {
                // Initialize all components with realistic data
                try self.generateMinimalState(params, &state);
                try self.generateModerateState(params, &state);
                try self.generateMaximalState(params, &state);

                // Initialize VarTheta and Rho with maximal complexity
                try state.initVartheta(self.allocator);
                try self.generateRandomTheta(params, .maximal, &state.vartheta.?);

                try state.initRho(self.allocator);
                try self.generateRandomRho(params, .maximal, &state.rho.?);
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
        self: *RandomStateGenerator,
        comptime params: Params,
        beta: *jamstate.Beta,
    ) !void {
        // Generate a random number of blocks (0 to max_blocks)
        const num_blocks = self.rng.uintAtMost(usize, beta.recent_history.max_blocks);

        for (0..num_blocks) |_| {
            // Generate random BlockInfo
            const block_info = try self.generateRandomBlockInfo(params);
            try beta.recent_history.addBlock(block_info);
        }
    }

    /// Helper function to generate a random BlockInfo
    fn generateRandomBlockInfo(self: *RandomStateGenerator, comptime _: Params) !@import("beta.zig").RecentHistory.BlockInfo {
        // Generate random header hash
        var header_hash: types.Hash = undefined;
        self.rng.bytes(&header_hash);

        // Generate random state root
        var state_root: types.Hash = undefined;
        self.rng.bytes(&state_root);

        // Generate random BEEFY root (v0.6.7: single hash instead of MMR peaks)
        var beefy_root: types.Hash = undefined;
        self.rng.bytes(&beefy_root);

        // Generate random work reports (0-5 reports)
        const num_reports = self.rng.uintAtMost(usize, 5);
        const work_reports = try self.allocator.alloc(types.ReportedWorkPackage, num_reports);
        for (work_reports) |*report| {
            self.rng.bytes(&report.hash);
            self.rng.bytes(&report.exports_root);
        }

        return @import("beta.zig").RecentHistory.BlockInfo{
            .header_hash = header_hash,
            .beefy_root = beefy_root,
            .state_root = state_root,
            .work_reports = work_reports,
        };
    }

    /// Generate random service accounts data
    fn generateRandomDelta(
        self: *RandomStateGenerator,
        comptime _: Params,
        delta: *jamstate.Delta,
    ) !void {
        // Generate only 1 simple service account to avoid performance issues
        const service_id = self.rng.int(u32);

        var service_account = @import("services.zig").ServiceAccount.init(self.allocator);

        // Generate only basic fields
        self.rng.bytes(&service_account.code_hash);
        service_account.balance = self.rng.int(u64) % 1000;
        service_account.min_gas_accumulate = self.rng.int(u64) % 1000;
        service_account.min_gas_on_transfer = self.rng.int(u64) % 1000;

        // Skip storage and preimage generation for now to avoid performance issues

        try delta.accounts.put(service_id, service_account);
    }

    /// Helper function to generate a random ServiceAccount
    fn generateRandomServiceAccount(self: *RandomStateGenerator) !@import("services.zig").ServiceAccount {
        var service_account = @import("services.zig").ServiceAccount.init(self.allocator);

        // Generate random code hash
        self.rng.bytes(&service_account.code_hash);

        // Generate random balance (0 to 1M tokens)
        service_account.balance = self.rng.int(u64) % 1_000_000;

        // Generate random gas limits
        service_account.min_gas_accumulate = self.rng.int(u64) % 100_000;
        service_account.min_gas_on_transfer = self.rng.int(u64) % 50_000;

        // Generate random storage entries (0-5 entries)
        const num_storage = self.rng.uintAtMost(u8, 5);
        for (0..num_storage) |_| {
            var storage_key: types.StateKey = undefined;
            self.rng.bytes(&storage_key);

            // Generate random storage value (1-512 bytes)
            const value_size = self.rng.uintAtMost(usize, 512) + 1;
            const storage_value = try self.allocator.alloc(u8, value_size);
            self.rng.bytes(storage_value);

            try service_account.data.put(storage_key, storage_value);
        }

        // Generate random preimage entries (0-3 entries)
        const num_preimages = self.rng.uintAtMost(u8, 3);
        for (0..num_preimages) |_| {
            var preimage_key: types.StateKey = undefined;
            self.rng.bytes(&preimage_key);

            // Generate random preimage data (1-1024 bytes)
            const preimage_size = self.rng.uintAtMost(usize, 1024) + 1;
            const preimage_data = try self.allocator.alloc(u8, preimage_size);
            self.rng.bytes(preimage_data);

            try service_account.data.put(preimage_key, preimage_data);

            // Create corresponding preimage lookup with random status
            var lookup = @import("services.zig").PreimageLookup{ .status = [_]?types.TimeSlot{null} ** 3 };
            const status_count = self.rng.uintAtMost(u8, 3) + 1;
            for (0..status_count) |i| {
                lookup.status[i] = self.rng.int(types.TimeSlot);
            }

            // Encode lookup and store in unified data container
            const encoded_lookup = try @import("services.zig").ServiceAccount.encodePreimageLookup(self.allocator, lookup);
            try service_account.data.put(preimage_key, encoded_lookup);
        }

        return service_account;
    }

    /// Generate random gamma (safrole state) data
    fn generateRandomGamma(
        self: *RandomStateGenerator,
        comptime params: Params,
        gamma: *jamstate.Gamma(params.validators_count, params.epoch_length),
    ) !void {
        // Generate random validator set (k field)
        try self.generateRandomValidatorSet(&gamma.k);

        // Generate random VRF root (z field) - 144-byte BLS public key
        self.rng.bytes(&gamma.z);

        // For now, only generate small simple structures to avoid performance issues
        // TODO: Implement full s field generation when structure is more stable

        // Generate minimal ticket array (a field) - limit to 3 for performance
        const num_tickets_a = self.rng.uintAtMost(usize, 3);
        gamma.a = try self.allocator.alloc(types.TicketBody, num_tickets_a);

        for (gamma.a) |*ticket| {
            self.rng.bytes(&ticket.id);
            ticket.attempt = self.rng.int(u8);
        }
    }

    /// Generate random phi (authorization queue) data
    fn generateRandomPhi(
        self: *RandomStateGenerator,
        comptime params: Params,
        phi: *jamstate.Phi(params.core_count, params.max_authorizations_queue_items),
    ) !void {
        // For each core, generate random authorizations at random indices
        for (0..params.core_count) |core| {
            // Generate random number of non-empty slots (0 to max_items, but limit to 5 for performance)
            const max_items = @min(params.max_authorizations_queue_items, 5);
            const num_non_empty = self.rng.uintAtMost(u8, max_items);

            // Create a list of indices and shuffle them
            var indices: [5]u8 = undefined;
            for (0..max_items) |i| {
                indices[i] = @intCast(i);
            }
            self.rng.shuffle(u8, indices[0..max_items]);

            // Set authorizations at the first num_non_empty shuffled indices
            for (0..num_non_empty) |i| {
                var hash: [32]u8 = undefined;
                self.rng.bytes(&hash);
                try phi.setAuthorization(core, indices[i], hash);
            }
        }
    }

    /// Generate random chi (privileged services) data
    fn generateRandomChi(
        self: *RandomStateGenerator,
        comptime _: Params,
        chi: *jamstate.Chi,
    ) !void {
        // Generate optional privileged service indices (30% chance of being null)
        chi.manager = if (self.rng.int(u8) % 10 < 3) null else self.rng.intRangeAtMost(u32, 1, 1000);
        
        // Generate assign list - must be exactly core_count entries
        // TODO: This needs to be updated when we support different params configurations
        const TINY_CORE_COUNT = 2; // From TINY_PARAMS
        for (0..TINY_CORE_COUNT) |_| {
            try chi.assign.append(chi.allocator, self.rng.intRangeAtMost(u32, 1, 1000));
        }
        
        chi.designate = if (self.rng.int(u8) % 10 < 3) null else self.rng.intRangeAtMost(u32, 1, 1000);

        // Generate always_accumulate services map (0-5 entries for performance)
        const num_always_accumulate = self.rng.uintAtMost(u8, 5);
        for (0..num_always_accumulate) |_| {
            const service_index = self.rng.intRangeAtMost(u32, 1, 1000);
            const gas_limit = self.rng.intRangeAtMost(u64, 1000, 100000);
            try chi.always_accumulate.put(service_index, gas_limit);
        }
    }

    /// Generate random psi (disputes) data
    fn generateRandomPsi(
        self: *RandomStateGenerator,
        comptime _: Params,
        psi: *jamstate.Psi,
    ) !void {
        // Generate random hashes for good_set (0-3 entries for performance)
        const good_count = self.rng.uintAtMost(u8, 3);
        for (0..good_count) |_| {
            var hash: [32]u8 = undefined;
            self.rng.bytes(&hash);
            try psi.good_set.put(hash, {});
        }

        // Generate random hashes for bad_set (0-3 entries for performance)
        const bad_count = self.rng.uintAtMost(u8, 3);
        for (0..bad_count) |_| {
            var hash: [32]u8 = undefined;
            self.rng.bytes(&hash);
            try psi.bad_set.put(hash, {});
        }

        // Generate random hashes for wonky_set (0-3 entries for performance)
        const wonky_count = self.rng.uintAtMost(u8, 3);
        for (0..wonky_count) |_| {
            var hash: [32]u8 = undefined;
            self.rng.bytes(&hash);
            try psi.wonky_set.put(hash, {});
        }

        // Generate random public keys for punish_set (0-3 entries for performance)
        const punish_count = self.rng.uintAtMost(u8, 3);
        for (0..punish_count) |_| {
            var pub_key: [32]u8 = undefined;
            self.rng.bytes(&pub_key);
            try psi.punish_set.put(pub_key, {});
        }
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
        self: *RandomStateGenerator,
        comptime params: Params,
        xi: *jamstate.Xi(params.epoch_length),
    ) !void {
        // Generate random work packages - they will be added to the newest slot automatically
        // Limit total work packages to avoid performance issues
        const total_packages = self.rng.uintAtMost(usize, 10);

        for (0..total_packages) |_| {
            // Generate random work package hash
            var work_package_hash: types.WorkPackageHash = undefined;
            self.rng.bytes(&work_package_hash);

            // Add work package (automatically goes to newest slot)
            try xi.addWorkPackage(work_package_hash);
        }
    }

    /// Generate random theta (reports ready) data
    fn generateRandomTheta(
        self: *RandomStateGenerator,
        comptime params: Params,
        complexity: StateComplexity,
        theta: *jamstate.VarTheta(params.epoch_length),
    ) !void {
        const WorkReportBuilder = @import("state_random_generator/work_report_builder.zig").WorkReportBuilder;

        // Generate work reports based on complexity
        const num_reports: usize = switch (complexity) {
            .minimal => 1,
            .moderate => self.rng.uintAtMost(usize, 2) + 1, // 1-2 reports
            .maximal => self.rng.uintAtMost(usize, 3) + 1, // 1-3 reports
        };

        for (0..num_reports) |_| {
            const work_report = try WorkReportBuilder.generateRandomWorkReport(
                params,
                self.allocator,
                self.rng,
                complexity,
            );

            // Add to theta's ready reports (use a random time slot within epoch bounds)
            const time_slot = self.rng.uintAtMost(types.TimeSlot, params.epoch_length - 1);
            try theta.addWorkReport(time_slot, work_report);
        }
    }

    /// Generate random rho (pending reports) data
    fn generateRandomRho(
        self: *RandomStateGenerator,
        comptime params: Params,
        complexity: StateComplexity,
        rho: *jamstate.Rho(params.core_count),
    ) !void {
        const WorkReportBuilder = @import("state_random_generator/work_report_builder.zig").WorkReportBuilder;

        // Populate cores based on complexity
        const num_cores_to_populate: usize = switch (complexity) {
            .minimal => 1,
            .moderate => self.rng.uintAtMost(usize, 2) + 1, // 1-2 cores
            .maximal => self.rng.uintAtMost(usize, 3) + 1, // 1-3 cores
        };

        for (0..num_cores_to_populate) |_| {
            const core_index = self.rng.uintAtMost(u16, params.core_count - 1);

            // Only populate if the slot is currently null
            if (rho.reports[core_index] == null) {
                const work_report = try WorkReportBuilder.generateRandomWorkReport(
                    params,
                    self.allocator,
                    self.rng,
                    complexity,
                );

                // Create AvailabilityAssignment with the work report and random timeout
                const assignment = types.AvailabilityAssignment{
                    .report = work_report,
                    .timeout = self.rng.int(types.TimeSlot),
                };

                // Create RhoEntry with the assignment
                const rho_entry = @import("reports_pending.zig").RhoEntry.init(
                    @intCast(core_index),
                    assignment,
                );

                rho.reports[core_index] = rho_entry;
            }
        }
    }

    /// Generate random validator set data
    fn generateRandomValidatorSet(
        self: *RandomStateGenerator,
        validator_set: *types.ValidatorSet,
    ) !void {
        // Generate random cryptographic keys for each validator
        for (validator_set.validators) |*validator| {
            // Generate random Bandersnatch public key (32 bytes)
            self.rng.bytes(&validator.bandersnatch);

            // Generate random Ed25519 public key (32 bytes)
            self.rng.bytes(&validator.ed25519);

            // Generate random BLS public key (144 bytes)
            self.rng.bytes(&validator.bls);

            // Generate random metadata (128 bytes)
            self.rng.bytes(&validator.metadata);
        }
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
    try std.testing.expect(state.vartheta != null); // v0.6.7: work reports queue
    // Note: state.theta (accumulation outputs) may or may not be initialized
    try std.testing.expect(state.rho != null);
    try std.testing.expect(state.iota != null);
    try std.testing.expect(state.kappa != null);
    try std.testing.expect(state.lambda != null);
}
