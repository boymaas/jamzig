const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const safrole = @import("safrole.zig");
const ring_vrf = @import("ring_vrf.zig");
const jam_params = @import("jam_params.zig");
const jamstate = @import("state.zig");
const codec = @import("codec.zig");

pub const logging = @import("sequoia/logging.zig");
const trace = @import("tracing.zig").scoped(.sequoia);

const Ed25519 = std.crypto.sign.Ed25519;
const Bls12_381 = crypto.bls12_381.Bls12_381;
const Bandersnatch = crypto.bandersnatch.Bandersnatch;

pub fn GenesisConfig(params: jam_params.Params) type {
    return struct {
        initial_slot: u32 = 0,
        initial_entropy: [4][32]u8,
        validator_keys: []ValidatorKeySet,

        params: jam_params.Params = params,

        pub fn buildWithRng(allocator: std.mem.Allocator, rng: *std.Random) !GenesisConfig(params) {
            const span = trace.span(.build_with_rng);
            defer span.deinit();
            span.debug("Building genesis config with RNG", .{});

            var config: GenesisConfig(params) = undefined;

            // set some details
            config.initial_slot = 0;

            // Initialize validator keys
            var validator_keys = try allocator.alloc(ValidatorKeySet, params.validators_count);
            errdefer allocator.free(validator_keys);

            span.debug("Initializing {d} validator keys", .{params.validators_count});
            for (0..params.validators_count) |i| {
                const key_span = span.child(.validator_key);
                defer key_span.deinit();
                key_span.debug("Generating key for validator {d}", .{i});

                var key_seed: [32]u8 = undefined;
                rng.bytes(&key_seed);
                key_span.trace("Generated key seed: {any}", .{std.fmt.fmtSliceHexLower(&key_seed)});

                validator_keys[i] = try ValidatorKeySet.init(key_seed);
            }

            config.validator_keys = validator_keys;

            // Generate initial entropy using ChaCha8 PRNG seeded with input seed
            span.debug("Generating initial entropy values", .{});
            var entropy: [4][32]u8 = undefined;
            for (0..4) |i| {
                rng.bytes(&entropy[i]);
                span.trace("Generated entropy[{d}]: {any}", .{ i, std.fmt.fmtSliceHexLower(&entropy[i]) });
            }

            config.initial_entropy = entropy;

            return config;
        }

        pub fn buildJamState(self: *const GenesisConfig(params), allocator: std.mem.Allocator, _: *std.Random) !jamstate.JamState(params) {
            const span = trace.span(.build_jam_state);
            defer span.deinit();
            span.debug("Building JAM state from genesis config", .{});

            // Initialize an empty genesis state with all components initialized
            var state = try jamstate.JamState(params).initGenesis(allocator);

            errdefer state.deinit(allocator);

            // Set the initial entropy values and timeslot from config
            state.eta.? = self.initial_entropy;
            state.tau.? = self.initial_slot;

            // Setup the initial validator set
            //
            // Determinism: All nodes must start with exactly the same validator ordering to reach consensus. Any shuffling would need to be deterministic and thus wouldn't add real randomization anyway.
            // Security: The initial ordering doesn't matter because:
            //
            // Block authoring in the first epoch uses the fallback function F(), which provides pseudo-random selection
            // The ticket system will naturally create randomization starting from the second epoch
            // The validator rotation system ensures proper cycling of responsibilities
            //
            // Simplicity: Starting with identical ordered sets makes the genesis state simpler to verify and reduces the chance of consensus errors during chain startup.

            // First, create initial validator set from the provided keys
            for (state.kappa.?.validators, 0..params.validators_count) |*validator, i| {
                const key = self.validator_keys[i];
                validator.* = .{
                    .bandersnatch = key.bandersnatch_keypair.public_key.toBytes(),
                    .ed25519 = key.ed25519_keypair.public_key.toBytes(),
                    .bls = [_]u8{0} ** 144, // TODO: fill out
                    .metadata = [_]u8{0} ** 128,
                };
            }

            // Create copies for lambda, iota
            std.mem.copyForwards(types.ValidatorData, state.lambda.?.validators, state.kappa.?.validators);
            std.mem.copyForwards(types.ValidatorData, state.iota.?.validators, state.kappa.?.validators);

            // Initialize safrole, so same order in gamma.?.k
            // γk (gamma_k)    : We start with the genesis validators since these are the active
            //                   validators for the first epoch.
            // γz (gamma_z)    : We need to create the ring root immediately so that validators
            //                   can start submitting tickets for the next epoch.
            // γa (gamma_a)    : Starts empty since no tickets have been submitted yet.
            // η (eta)         : We need all four entropy values for various protocol functions.
            //                   We initialize them deterministically based on genesis
            //                   configuration to ensure all nodes start with the same values.
            // γs (gamma_s)    : Most importantly, we use the fallback function to create our
            //                   initial slot assignments. This gives us a deterministic but
            //                   pseudo-random sequence of block authors for the first epoch.
            std.mem.copyForwards(types.ValidatorData, state.gamma.?.k.validators, state.kappa.?.validators);

            // Gamma_s with initial empty tickets from the start
            state.gamma.?.s.deinit(allocator);
            state.gamma.?.s = .{
                .keys = try safrole.gammaS_Fallback(allocator, state.eta.?[2], params.epoch_length, state.kappa.?),
            };

            // Calculate gamma_z (Bandersnatch ring root) from gamma_k validators
            {
                const pub_keys = try state.gamma.?.k.getBandersnatchPublicKeys(allocator);
                defer allocator.free(pub_keys);
                var verifier = try ring_vrf.RingVerifier.init(pub_keys);
                defer verifier.deinit();
                state.gamma.?.z = try verifier.get_commitment();
            }

            return state;
        }

        pub fn deinit(self: *GenesisConfig(params), allocator: std.mem.Allocator) void {
            allocator.free(self.validator_keys);
        }
    };
}

const ValidatorKeySet = struct {
    bandersnatch_keypair: Bandersnatch.KeyPair,
    ed25519_keypair: Ed25519.KeyPair,
    bls12_381_keypair: Bls12_381.KeyPair,

    const SEED_LENGTH = 32;

    pub fn init(seed: [SEED_LENGTH]u8) !ValidatorKeySet {
        return ValidatorKeySet{
            .bandersnatch_keypair = try Bandersnatch.KeyPair.create(&seed),
            .ed25519_keypair = try Ed25519.KeyPair.create(seed),
            .bls12_381_keypair = try Bls12_381.KeyPair.create(&seed),
        };
    }

    pub fn createDeterministic(index: u32) !ValidatorKeySet {
        var seed: [SEED_LENGTH]u8 = [_]u8{0} ** SEED_LENGTH;
        std.mem.writeInt(u32, seed[0..4], index, .little);
        return init(seed);
    }
};

pub fn BlockBuilder(comptime params: jam_params.Params) type {
    return struct {
        const Self = @This();

        config: GenesisConfig(params),

        allocator: std.mem.Allocator,
        state: jamstate.JamState(params),
        current_slot: types.TimeSlot = 0,

        last_header_hash: ?types.Hash,
        last_state_root: ?types.Hash,

        rng: *std.Random,

        /// Initialize the BlockBuilder with required state
        pub fn init(
            allocator: std.mem.Allocator,
            config: GenesisConfig(params),
            rng: *std.Random,
        ) !Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .state = try config.buildJamState(allocator, rng),
                .current_slot = config.initial_slot,
                .last_header_hash = null,
                .last_state_root = null,
                .rng = rng,
            };
        }

        pub fn deinit(self: *Self) void {
            self.config.deinit(self.allocator);
            self.state.deinit(self.allocator);
        }

        /// Generate the block seal signature using either ticket or fallback mode
        fn generateBlockSeal(
            self: *Self,
            header: *const types.Header,
            author_keys: ValidatorKeySet,
            eta_prime: *const types.Eta,
            gamma_s: *const types.GammaS,
        ) !types.BandersnatchVrfSignature {
            // TODO: optimize, no allocation needed
            var context = std.ArrayList(u8).init(self.allocator);
            defer context.deinit();

            const span = trace.span(.generate_seal_context);
            defer span.deinit();

            switch (gamma_s.*) {
                .tickets => |tickets| {
                    // Ticket-based sealing 6.15
                    span.debug("Using ticket-based sealing", .{});
                    const slot_index = header.slot % params.validators_count;
                    const ticket = tickets[slot_index];

                    span.trace("Slot index: {d}, ticket attempt: {d}", .{ slot_index, ticket.attempt });

                    try context.appendSlice("jam_ticket_seal");
                    try context.appendSlice(&eta_prime[3]);
                    try context.append(ticket.attempt);
                },
                .keys => {
                    // Fallback sealing
                    span.debug("Using fallback sealing", .{});
                    span.trace("Using eta_prime[3]: {any}", .{std.fmt.fmtSliceHexLower(&eta_prime[3])});

                    try context.appendSlice("jam_fallback_seal");
                    try context.appendSlice(&eta_prime[3]);
                },
            }

            // Create bandersnatch signature
            const header_unsigned = try codec.serializeAlloc(
                types.HeaderUnsigned,
                params,
                self.allocator,
                types.HeaderUnsigned.fromHeaderShared(header),
            );
            defer self.allocator.free(header_unsigned);

            // Generate and return the seal signature
            _ = author_keys;
            return [_]u8{0} ** 96;
        }

        /// Generate the VRF entropy signature using the seal output
        fn generateEntropySignature(
            self: *Self,
            seal_output: types.BandersnatchVrfSignature,
            author_keys: ValidatorKeySet,
        ) !types.BandersnatchVrfSignature {
            var message = std.ArrayList(u8).init(self.allocator);
            defer message.deinit();

            // Construct entropy message
            try message.appendSlice("jam_entropy");
            try message.appendSlice(&seal_output);

            // Create VRF prover
            _ = author_keys;
            return [_]u8{0} ** 96;
        }

        // Build the next block in the chain with proper sealing
        pub fn buildNextBlock(self: *Self) !types.Block {
            const span = trace.span(.build_next_block);
            defer span.deinit();
            span.debug("Building next block at slot {d}", .{self.current_slot + 1});

            // Select block producer for this slot
            const author_index = try self.selectBlockAuthor();
            span.debug("Selected block author index: {d}", .{author_index});

            const author_keys = self.config.validator_keys[author_index];

            // Ensure new slot is greater than parent
            const new_slot = @max(
                self.current_slot + 1,
                self.state.tau.? + 1,
            );
            self.current_slot = new_slot;

            // Create initial header without signatures
            var header = types.Header{
                .parent = if (self.last_header_hash) |hash| hash else std.mem.zeroes(types.Hash),
                .parent_state_root = if (self.last_state_root) |root| root else std.mem.zeroes(types.Hash),
                .extrinsic_hash = std.mem.zeroes(types.Hash),
                .slot = self.current_slot,
                .author_index = author_index,
                .epoch_mark = null,
                .tickets_mark = null,
                .offenders_mark = &[_]types.Ed25519Public{},
                .entropy_source = undefined,
                .seal = undefined,
            };

            // Generate block seal
            header.seal = try self.generateBlockSeal(
                &header,
                author_keys,
                &self.state.eta.?,
                &self.state.gamma.?.s,
            );

            // Generate entropy signature using seal output
            header.entropy_source = try self.generateEntropySignature(
                header.seal,
                author_keys,
            );

            // Create empty extrinsic for now
            const extrinsic = types.Extrinsic{
                .tickets = .{ .data = &[_]types.TicketEnvelope{} },
                .preimages = .{ .data = &[_]types.Preimage{} },
                .guarantees = .{ .data = &[_]types.ReportGuarantee{} },
                .assurances = .{ .data = &[_]types.AvailAssurance{} },
                .disputes = .{
                    .verdicts = &[_]types.Verdict{},
                    .culprits = &[_]types.Culprit{},
                    .faults = &[_]types.Fault{},
                },
            };

            // Assemble complete block
            const block = types.Block{
                .header = header,
                .extrinsic = extrinsic,
            };

            // Update block history
            self.last_header_hash = try block.header.header_hash(params, self.allocator);
            self.last_state_root = try self.state.buildStateRoot(self.allocator);

            return block;
        }

        fn selectBlockAuthor(self: *Self) !types.ValidatorIndex {
            const span = trace.span(.select_block_author);
            defer span.deinit();
            span.debug("Selecting block author for slot {d}", .{self.current_slot});

            if (self.state.gamma) |gamma| {
                // Get index into gamma_s using current slot
                const slot_in_epoch = self.current_slot % params.epoch_length;
                span.debug("Slot in epoch: {d}", .{slot_in_epoch});

                // Select based on gamma_s mode
                switch (gamma.s) {
                    .tickets => |_| {
                        span.debug("Ticket-based author selection not implemented", .{});
                        return error.TicketsNotImplementedYet;
                    },
                    .keys => |keys| {
                        span.debug("Using fallback key-based author selection", .{});

                        // Ensure we have the correct number of keys
                        std.debug.assert(keys.len == params.epoch_length);

                        // Encode the slot index into 4 bytes as per equation 6.26
                        var encoded_slot: [4]u8 = undefined;
                        std.mem.writeInt(u32, &encoded_slot, @intCast(slot_in_epoch), .little);

                        // Get entropy from eta[2] for the fallback function as per equation 6.24
                        var entropy = self.state.eta.?[2];

                        // Hash entropy concatenated with encoded slot
                        span.trace("Using entropy for hash: {any}", .{std.fmt.fmtSliceHexLower(&entropy)});
                        span.trace("Using encoded slot: {any}", .{std.fmt.fmtSliceHexLower(&encoded_slot)});

                        var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
                        hasher.update(&entropy);
                        hasher.update(&encoded_slot);
                        var hash: [32]u8 = undefined;
                        hasher.final(&hash);
                        span.trace("Generated hash: {any}", .{std.fmt.fmtSliceHexLower(&hash)});

                        // Take first 4 bytes for deterministic validator selection, as per equation 6.26
                        const index_bytes = hash[0..4].*;
                        const validator_index = std.mem.readInt(u32, &index_bytes, .little) % keys.len;
                        const validator_key = keys[validator_index];
                        span.debug("Selected validator index {d} from key set", .{validator_index});
                        span.trace("Using validator key: {any}", .{std.fmt.fmtSliceHexLower(&validator_key)});

                        // TODO: ensure this is kappa'
                        return try self.state.kappa.?.findValidatorIndex(.BandersnatchPublic, validator_key);
                    },
                }
            }
            return error.NoValidatorSet;
        }
    };
}

pub fn createTinyBlockBuilder(
    allocator: std.mem.Allocator,
    rng: *std.Random,
) !BlockBuilder(jam_params.TINY_PARAMS) {
    const config = try GenesisConfig(jam_params.TINY_PARAMS).buildWithRng(allocator, rng);
    return BlockBuilder(jam_params.TINY_PARAMS).init(allocator, config, rng);
}

fn generateValidatorKeys(allocator: std.mem.Allocator, count: u32) ![]ValidatorKeySet {
    var keys = try allocator.alloc(ValidatorKeySet, count);
    errdefer allocator.free(keys);

    for (0..count) |i| {
        keys[i] = try ValidatorKeySet.createDeterministic(@intCast(i));
    }
    return keys;
}
