const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const safrole = @import("safrole.zig");
const ring_vrf = @import("ring_vrf.zig");
const jam_params = @import("jam_params.zig");
const jamstate = @import("state.zig");
const codec = @import("codec.zig");
const time = @import("time.zig");

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
                .keys = try safrole.epoch_handler.entropyBasedKeySelector(allocator, state.eta.?[2], params.epoch_length, state.kappa.?),
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
            self.* = undefined;
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
            .bandersnatch_keypair = try Bandersnatch.KeyPair.generateDeterministic(&seed),
            .ed25519_keypair = try Ed25519.KeyPair.generateDeterministic(seed),
            .bls12_381_keypair = try Bls12_381.KeyPair.generateDeterministic(&seed),
        };
    }

    pub fn createDeterministic(index: u32) !ValidatorKeySet {
        var seed: [SEED_LENGTH]u8 = [_]u8{0} ** SEED_LENGTH;
        std.mem.writeInt(u32, seed[0..4], index, .little);
        return init(seed);
    }
};

// Manages entropy generation and VRF output for block production
const EntropyManager = struct {
    pub fn generateVrfOutputFallback(author_keys: *const ValidatorKeySet, eta_prime: *const types.Eta) !types.BandersnatchVrfOutput {
        const span = trace.span(.generate_vrf_output_fallback);
        defer span.deinit();
        span.debug("Generating VRF output using fallback function", .{});

        const context = "jam_fallback_seal" ++ eta_prime[3];
        span.trace("Using eta_prime[3]: {any}", .{std.fmt.fmtSliceHexLower(&eta_prime[3])});
        span.trace("Using context: {s}", .{context});

        span.debug("Signing with Bandersnatch keypair", .{});
        span.trace("Using public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});
        const signature = try author_keys.bandersnatch_keypair
            .sign(context, &[_]u8{});
        span.trace("Generated signature: {s}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

        const output = try signature.outputHash();
        span.debug("Generated VRF output", .{});
        span.trace("VRF output: {s}", .{std.fmt.fmtSliceHexLower(&output)});

        return output;
    }

    pub fn generateEntropySourceFallback(
        author_keys: ValidatorKeySet,
        eta_prime: *const types.Eta,
    ) !Bandersnatch.Signature {
        const span = trace.span(.generate_entropy_source_fallback);
        defer span.deinit();
        span.debug("Generating entropy source using fallback method", .{});

        span.debug("Generating VRF output", .{});
        const vrf_output = try generateVrfOutputFallback(&author_keys, eta_prime);
        span.trace("VRF output: {any}", .{std.fmt.fmtSliceHexLower(&vrf_output)});

        // Now sign with our Bandersnatch keypair
        const context = "jam_entropy" ++ vrf_output;
        span.trace("Signing context: {s}", .{context});
        span.trace("Using public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});

        span.debug("Generating Bandersnatch signature", .{});
        const entropy_source = try author_keys.bandersnatch_keypair
            .sign(context, &[_]u8{});

        span.debug("Generated entropy source signature", .{});
        span.trace("Entropy source bytes: {any}", .{std.fmt.fmtSliceHexLower(&entropy_source.toBytes())});

        return entropy_source;
    }

    pub fn generateEntropySourceTicket(
        author_keys: ValidatorKeySet,
        ticket: types.TicketBody,
    ) !Bandersnatch.Signature {
        const span = trace.span(.generate_entropy_source_ticket);
        defer span.deinit();
        span.debug("Generating entropy source using ticket method", .{});

        // Now sign with our Bandersnatch keypair
        const context = "jam_entropy" ++ ticket.id;
        span.trace("Signing context: {s}", .{context});
        span.trace("Using public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});

        span.debug("Generating Bandersnatch signature", .{});
        const entropy_source = try author_keys.bandersnatch_keypair
            .sign(context, &[_]u8{});

        span.debug("Generated entropy source signature", .{});
        span.trace("Entropy source bytes: {any}", .{std.fmt.fmtSliceHexLower(&entropy_source.toBytes())});

        return entropy_source;
    }

    pub fn updateEntropy(current_eta: types.Eta, entropy_source: types.BandersnatchVrfOutput) types.Hash {
        return @import("entropy.zig").update(current_eta[0], entropy_source);
    }
};

// Manages ticket registries for tracking validator tickets across epochs
const TicketRegistry = struct {
    const Entry = struct {
        validator_index: types.ValidatorIndex,
        attempt: u8,
    };

    allocator: std.mem.Allocator,
    current: std.AutoHashMap(types.OpaqueHash, Entry),
    previous: std.AutoHashMap(types.OpaqueHash, Entry),

    pub fn init(allocator: std.mem.Allocator) TicketRegistry {
        return .{
            .allocator = allocator,
            .current = std.AutoHashMap(types.OpaqueHash, Entry).init(allocator),
            .previous = std.AutoHashMap(types.OpaqueHash, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *TicketRegistry) void {
        self.current.deinit();
        self.previous.deinit();
        self.* = undefined;
    }

    pub fn rotateRegistries(self: *TicketRegistry) void {
        const span = trace.span(.rotate_registries);
        defer span.deinit();
        span.debug("Rotating ticket registries at epoch boundary", .{});

        // Tickets submitted in epoch N are used for block production in epoch N+1.
        // This rotation ensures we always have the correct mapping when looking up
        // which validator created a winning ticket.
        const temp = self.previous;
        self.previous = self.current;
        self.current = temp;
        self.current.clearRetainingCapacity();
    }

    pub fn registerTicket(self: *TicketRegistry, ticket_id: types.OpaqueHash, validator_index: types.ValidatorIndex, attempt: u8) !void {
        try self.current.put(ticket_id, .{
            .validator_index = validator_index,
            .attempt = attempt,
        });
    }

    pub fn lookupTicket(self: *const TicketRegistry, ticket_id: types.OpaqueHash) ?Entry {
        return self.previous.get(ticket_id);
    }
};

// Parameter structs for cleaner function signatures
const SealParams = struct {
    allocator: std.mem.Allocator,
    header: *const types.Header,
    author_keys: ValidatorKeySet,
    eta_prime: *const types.Eta,
};

const TicketGenerationParams = struct {
    validator: ValidatorKeySet,
    validator_index: types.ValidatorIndex,
    attempt: u8,
    eta_prime: *const types.Eta,
    gamma_z: types.Hash,
};

// Generates block seals using different strategies (fallback vs ticket-based)
const BlockSealGenerator = struct {
    pub fn generateBlockSealFallback(
        allocator: std.mem.Allocator,
        header: *const types.Header, // Assumes entropy_source is already set
        author_keys: ValidatorKeySet,
        eta_prime: *const types.Eta,
        comptime params: jam_params.Params,
    ) !Bandersnatch.Signature {
        const span = trace.span(.generate_seal_fallback);
        defer span.deinit();
        span.debug("Generating block seal using fallback method", .{});

        const context = "jam_fallback_seal" ++ eta_prime[3];
        span.trace("Using eta_prime[3]: {any}", .{std.fmt.fmtSliceHexLower(&eta_prime[3])});
        span.trace("Using context: {s}", .{context});
        span.trace("Using author public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});

        // Create bandersnatch signature
        span.debug("Serializing unsigned header", .{});
        const header_unsigned = try codec.serializeAlloc(
            types.HeaderUnsigned,
            params,
            allocator,
            types.HeaderUnsigned.fromHeaderShared(header),
        );
        defer allocator.free(header_unsigned);
        span.trace("Unsigned header bytes: {any}", .{std.fmt.fmtSliceHexLower(header_unsigned)});

        // Generate and return the seal signature
        span.debug("Generating Bandersnatch signature", .{});
        const signature = try author_keys.bandersnatch_keypair
            .sign(context, header_unsigned);

        span.debug("Generated block seal signature", .{});
        span.trace("Seal signature bytes: {any}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

        return signature;
    }

    pub fn generateBlockSealTickets(
        allocator: std.mem.Allocator,
        header: *const types.Header, // Assumes entropy_source is already set
        author_keys: ValidatorKeySet,
        eta_prime: *const types.Eta,
        ticket: types.TicketBody,
        comptime params: jam_params.Params,
    ) !Bandersnatch.Signature {
        const span = trace.span(.generate_seal_tickets);
        defer span.deinit();
        span.debug("Generating block seal using tickets method", .{});

        const context = "jam_ticket_seal" ++ eta_prime[3] ++ [_]u8{ticket.attempt};
        span.trace("Using eta_prime[3]: {any}", .{std.fmt.fmtSliceHexLower(&eta_prime[3])});
        span.trace("Using context: {s}", .{context});
        span.trace("Using author public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});

        // Create bandersnatch signature
        span.debug("Serializing unsigned header", .{});
        const header_unsigned = try codec.serializeAlloc(
            types.HeaderUnsigned,
            params,
            allocator,
            types.HeaderUnsigned.fromHeaderShared(header),
        );
        defer allocator.free(header_unsigned);
        span.trace("Unsigned header bytes: {any}", .{std.fmt.fmtSliceHexLower(header_unsigned)});

        // Generate and return the seal signature
        span.debug("Generating Bandersnatch signature", .{});
        const signature = try author_keys.bandersnatch_keypair
            .sign(context, header_unsigned);

        span.debug("Generated block seal signature", .{});
        span.trace("Seal signature bytes: {any}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

        return signature;
    }
};

// Manages ticket submission logic and generation
const TicketSubmissionManager = struct {
    // Constants for ticket submission probability
    const PROBABILITY_RANGE = 10;
    const PROBABILITY_THRESHOLD = 2; // 20% chance when random value < 2 out of 10

    const GeneratedTicket = struct {
        envelope: types.TicketEnvelope,
        id: types.OpaqueHash,
    };

    pub fn shouldSubmitTicket(rng: *std.Random) bool {
        return rng.intRangeAtMost(u8, 0, PROBABILITY_RANGE - 1) < PROBABILITY_THRESHOLD;
    }

    pub fn generateSingleTicket(
        validator: ValidatorKeySet,
        validator_index: usize,
        gamma_k_keys: []const types.BandersnatchPublic,
        attempt_index: u8,
        eta_prime: *const types.Eta,
        gamma_z: *const types.BandersnatchVrfRoot,
        comptime params: jam_params.Params,
    ) !GeneratedTicket {
        const span = trace.span(.generate_single_ticket);
        defer span.deinit();
        span.debug("Generating ticket for validator {d}", .{validator_index});

        // Create prover for this validator
        var prover = try ring_vrf.RingProver.init(
            validator.bandersnatch_keypair.secret_key.toBytes(),
            gamma_k_keys,
            validator_index,
        );
        defer prover.deinit();

        // Sign with prover to generate ticket
        const vrf_input = "jam_ticket_seal" ++ eta_prime[2] ++ [_]u8{attempt_index};
        const vrf_proof = try prover.sign(
            vrf_input,
            &[_]u8{},
        );

        span.trace("Ticket generation values:", .{});
        span.trace("  Validator index: {d}", .{validator_index});
        span.trace("  Attempt number: {d}", .{attempt_index});
        span.trace("  Ring size: {d}", .{params.validators_count});
        span.trace("  Ring values:", .{});
        span.trace("    Gamma_z: {s}", .{std.fmt.fmtSliceHexLower(gamma_z)});
        span.trace("  VRF input:", .{});
        span.trace("    Context: {s}", .{vrf_input});
        span.trace("    Eta[2]: {s}", .{std.fmt.fmtSliceHexLower(&eta_prime[2])});
        span.trace("  VRF output:", .{});
        span.trace("    Proof: {s}", .{std.fmt.fmtSliceHexLower(&vrf_proof)});
        span.trace("    Public key: {s}", .{std.fmt.fmtSliceHexLower(&validator.bandersnatch_keypair.public_key.toBytes())});

        const ticket_id = try ring_vrf.verifyRingSignatureAgainstCommitment(
            gamma_z,
            params.validators_count,
            vrf_input,
            &[_]u8{},
            &vrf_proof,
        );
        span.debug("  Ticket ID: {s}", .{std.fmt.fmtSliceHexLower(&ticket_id)});

        // Create and return ticket
        const ticket = types.TicketEnvelope{
            .attempt = attempt_index,
            .signature = vrf_proof,
        };
        return .{ .envelope = ticket, .id = ticket_id };
    }
};

pub fn BlockBuilder(comptime params: jam_params.Params) type {
    return struct {
        const Self = @This();

        config: GenesisConfig(params),

        allocator: std.mem.Allocator,
        state: jamstate.JamState(params),

        block_time: params.Time(),

        last_header_hash: ?types.Hash,
        last_state_root: ?types.Hash,

        rng: *std.Random,

        tickets_submitted: [params.validators_count]u8,
        ticket_registry: TicketRegistry,

        /// Initialize the BlockBuilder with required state
        pub fn init(
            allocator: std.mem.Allocator,
            config: GenesisConfig(params), // Takes ownership of the config
            rng: *std.Random,
        ) !Self {
            const state = try config.buildJamState(allocator, rng);

            return Self{
                .allocator = allocator,
                .config = config,
                .state = state,
                .block_time = params.Time().init(config.initial_slot, config.initial_slot),
                .last_header_hash = null,
                .last_state_root = try state.buildStateRoot(allocator),
                .rng = rng,
                .tickets_submitted = std.mem.zeroes([params.validators_count]u8),
                .ticket_registry = TicketRegistry.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // config is owned by calling scope
            self.config.deinit(self.allocator);
            self.state.deinit(self.allocator);
            self.ticket_registry.deinit();
            self.* = undefined;
        }

        fn handleEpochTransition(self: *Self) void {
            if (self.block_time.isNewEpoch()) {
                self.ticket_registry.rotateRegistries();
                // Reset ticket counts for next epoch
                self.tickets_submitted = std.mem.zeroes([params.validators_count]u8);
            }
        }

        fn determineGammaSPrime(self: *Self) !struct { bool, types.GammaS } {
            const span = trace.span(.determine_gamma_s_prime);
            defer span.deinit();
            // Determine gamma_s_prime based on ticket submission state
            if (self.block_time.priorWasInTicketSubmissionTail() and
                self.block_time.isConsecutiveEpoch())
            {
                span.debug("Detected isConsecutiveEpoch predicting GammaS'", .{});
                span.trace("Current GammaA length: {d} epoch length {d}", .{ self.state.gamma.?.a.len, params.epoch_length });
                if (self.state.gamma.?.a.len == params.epoch_length) {
                    span.debug("Using tickets for gamma_s_prime", .{});
                    return .{ true, .{ .tickets = try @import("safrole/ordering.zig").outsideInOrdering(types.TicketBody, self.allocator, self.state.gamma.?.a) } };
                } else {
                    span.debug("Using keys for gamma_s_prime", .{});
                    return .{ true, .{
                        .keys = try safrole.epoch_handler.entropyBasedKeySelector(
                            self.allocator,
                            self.state.eta.?[2],
                            params.epoch_length,
                            self.state.kappa.?,
                        ),
                    } };
                }
            }
            span.debug("NOT isConsecutiveEpoch using state gamma_s_prime", .{});
            return .{ false, self.state.gamma.?.s };
        }

        fn prepareEpochMark(self: *const Self) !?types.EpochMark {
            if (!self.block_time.isNewEpoch()) return null;

            return .{
                .entropy = self.state.eta.?[0],
                .tickets_entropy = self.state.eta.?[1],
                .validators = try self.state.gamma.?.k.getEpochMarkValidatorsKeys(self.allocator), // TODO: this has to be gamma_k_prime
            };
        }

        fn prepareTicketsMark(self: *const Self) !?types.TicketsMark {
            if (self.block_time.didCrossTicketSubmissionEndInSameEpoch() and
                self.state.gamma.?.a.len == params.epoch_length)
            {
                return .{ .tickets = try safrole.ordering.outsideInOrdering(types.TicketBody, self.allocator, self.state.gamma.?.a) };
            }
            return null;
        }

        fn calculateEtaPrime(self: *const Self, eta_current: *const types.Eta) types.Eta {
            var eta_prime = eta_current.*;
            if (self.block_time.isNewEpoch()) {
                // Rotate the entropy values
                eta_prime[3] = eta_current[2];
                eta_prime[2] = eta_current[1];
                eta_prime[1] = eta_current[0];
            }
            return eta_prime;
        }

        fn generateBlockContent(self: *Self, eta_prime: *const types.Eta) !types.Extrinsic {
            const span = trace.span(.generate_block_content);
            defer span.deinit();

            var tickets = types.TicketsExtrinsic{ .data = &[_]types.TicketEnvelope{} };
            if (self.block_time.slotsUntilTicketSubmissionEnds()) |remaining_slots| {
                span.debug("Generating ticket submissions - {d} slots remaining", .{remaining_slots});
                tickets = .{ .data = try self.generateTickets(eta_prime) };
            } else {
                span.debug("Outside ticket submission period", .{});
            }

            return types.Extrinsic{
                .tickets = tickets,
                .preimages = .{ .data = &[_]types.Preimage{} },
                .guarantees = .{ .data = &[_]types.ReportGuarantee{} },
                .assurances = .{ .data = &[_]types.AvailAssurance{} },
                .disputes = .{
                    .verdicts = &[_]types.Verdict{},
                    .culprits = &[_]types.Culprit{},
                    .faults = &[_]types.Fault{},
                },
            };
        }

        fn sealBlock(
            self: *Self,
            header: *types.Header,
            gamma_s_prime: types.GammaS,
            author_keys: ValidatorKeySet,
            eta_prime: *const types.Eta,
        ) !void {
            const block_seal = switch (gamma_s_prime) {
                .keys => try BlockSealGenerator.generateBlockSealFallback(
                    self.allocator,
                    header,
                    author_keys,
                    eta_prime,
                    params,
                ),
                .tickets => |t| try BlockSealGenerator.generateBlockSealTickets(
                    self.allocator,
                    header,
                    author_keys,
                    eta_prime,
                    t[self.block_time.current_slot_in_epoch],
                    params,
                ),
            };
            header.seal = block_seal.toBytes();
        }

        // Build the next block in the chain with proper sealing
        pub fn buildNextBlock(self: *Self) !types.Block {
            const span = trace.span(.build_next_block);
            defer span.deinit();

            // Progress to next slot and update state root
            self.block_time = self.block_time.progressSlots(1);
            self.last_state_root = try self.state.buildStateRoot(self.allocator);

            span.debug("Building next block at slot {d} (epoch {d}, slot in epoch {d})", .{
                self.block_time.current_slot,
                self.block_time.current_epoch,
                self.block_time.current_slot_in_epoch,
            });

            // Handle epoch transition if needed
            self.handleEpochTransition();

            // Determine gamma_s_prime for block production
            var r = try self.determineGammaSPrime();
            defer if (r[0]) r[1].deinit(self.allocator);
            const gamma_s_prime = r[1];

            // Select block author and prepare block components
            const author_index = try self.selectBlockAuthor(gamma_s_prime);
            span.debug("Selected block author index: {d}", .{author_index});

            // Validate author index before use
            if (author_index >= self.config.validator_keys.len) {
                return error.InvalidValidatorIndex;
            }
            const author_keys = self.config.validator_keys[author_index];
            const epoch_mark = try self.prepareEpochMark();
            const tickets_mark = try self.prepareTicketsMark();

            // Calculate eta_prime and generate entropy source
            const eta_current = &self.state.eta.?;
            var eta_prime = self.calculateEtaPrime(eta_current);

            const entropy_source = switch (gamma_s_prime) {
                .tickets => |tickets| try EntropyManager.generateEntropySourceTicket(author_keys, tickets[self.block_time.current_slot_in_epoch]),
                .keys => try EntropyManager.generateEntropySourceFallback(author_keys, &eta_prime),
            };
            eta_prime[0] = EntropyManager.updateEntropy(self.state.eta.?, try entropy_source.outputHash());

            // Generate extrinsic content
            const extrinsic = try self.generateBlockContent(&eta_prime);

            // Create header
            var header = types.Header{
                .parent = self.last_header_hash orelse std.mem.zeroes(types.Hash),
                .parent_state_root = self.last_state_root orelse std.mem.zeroes(types.Hash),
                .extrinsic_hash = try extrinsic.calculateHash(params, self.allocator),
                .slot = self.block_time.current_slot,
                .author_index = author_index,
                .epoch_mark = epoch_mark,
                .tickets_mark = tickets_mark,
                .offenders_mark = &[_]types.Ed25519Public{},
                .entropy_source = entropy_source.toBytes(),
                .seal = undefined,
            };

            // Seal the block
            try self.sealBlock(&header, gamma_s_prime, author_keys, &eta_prime);

            // Assemble complete block
            const block = types.Block{
                .header = header,
                .extrinsic = extrinsic,
            };

            // Update block history
            self.last_header_hash = try block.header.header_hash(params, self.allocator);

            span.trace("block:\n{s}", .{types.fmt.format(&block)});
            return block;
        }

        fn generateTickets(
            self: *Self,
            eta_prime: *const types.Eta,
        ) ![]types.TicketEnvelope {
            const span = trace.span(.generate_tickets);
            defer span.deinit();
            span.debug("Generating tickets", .{});

            var generated = std.ArrayList(TicketSubmissionManager.GeneratedTicket).init(self.allocator);
            defer generated.deinit();

            // The ring
            const gamma_k_keys = try self.state.gamma.?.k.getBandersnatchPublicKeys(self.allocator);
            defer self.allocator.free(gamma_k_keys);

            // Ring VRF verification ensures ticket authenticity without revealing
            // validator identity, maintaining anonymity while preventing forgery.
            // Each validator has a probabilistic chance to submit tickets to ensure
            // fair distribution and prevent gaming of the system.
            for (self.config.validator_keys, 0..) |validator, index| {
                // Validate validator index
                if (index >= params.validators_count) {
                    span.err("Invalid validator index {d}", .{index});
                    continue;
                }

                // Skip if validator already submitted max tickets
                if (self.tickets_submitted[index] >= params.max_ticket_entries_per_validator) {
                    span.trace("Validator {d} already submitted max tickets", .{index});
                    continue;
                }

                // Probabilistic submission prevents validators from gaming the system
                // by submitting tickets at predictable times. The ~20% chance ensures
                // reasonable ticket distribution across the submission period.
                if (TicketSubmissionManager.shouldSubmitTicket(self.rng)) {
                    const attempt_index = self.tickets_submitted[index];
                    const generated_ticket = try TicketSubmissionManager.generateSingleTicket(
                        validator,
                        index,
                        gamma_k_keys,
                        attempt_index,
                        eta_prime,
                        &self.state.gamma.?.z,
                        params,
                    );
                    try generated.append(generated_ticket);

                    // After creating the ticket and getting its ID:
                    const validator_index = try self.state.kappa.?.findValidatorIndex(
                        .BandersnatchPublic,
                        validator.bandersnatch_keypair.public_key.toBytes(),
                    );
                    try self.ticket_registry.registerTicket(generated_ticket.id, validator_index, attempt_index);

                    // Increment ticket count for this validator
                    self.tickets_submitted[index] += 1;

                    // Only include up to K tickets per block
                    if (generated.items.len >= params.max_tickets_per_extrinsic) {
                        span.debug("Reached max tickets per block ({d})", .{params.max_ticket_entries_per_validator});
                        break;
                    }
                }
            }

            // Sort tickets by VRF output (ticket identifier)
            // Sorting by VRF output ensures deterministic ordering that all nodes
            // can replicate, maintaining consensus while preserving the unpredictability
            // of which validators' tickets appear in which positions.
            if (generated.items.len > 0) {
                span.debug("Sorting {d} tickets by VRF output", .{generated.items.len});
                std.sort.insertion(
                    TicketSubmissionManager.GeneratedTicket,
                    generated.items,
                    {},
                    struct {
                        pub fn lessThan(_: void, a: TicketSubmissionManager.GeneratedTicket, b: TicketSubmissionManager.GeneratedTicket) bool {
                            return std.mem.lessThan(u8, &a.id, &b.id);
                        }
                    }.lessThan,
                );
            }

            // TODO: this could be avoided
            var tickets = try std.ArrayList(types.TicketEnvelope).initCapacity(self.allocator, generated.items.len);
            for (generated.items) |ticket| {
                try tickets.append(ticket.envelope);
            }

            return tickets.toOwnedSlice();
        }

        fn selectBlockAuthorFromTickets(self: *Self, tickets: []const types.TicketBody, slot_in_epoch: u64) !types.ValidatorIndex {
            const span = trace.span(.select_block_author_tickets);
            defer span.deinit();
            span.debug("Using ticket-based author selection for slot {d}", .{slot_in_epoch});

            // Validate slot index
            if (slot_in_epoch >= tickets.len) {
                return error.InvalidSlotInEpoch;
            }

            // Get ticket for this slot
            const ticket = tickets[slot_in_epoch];
            span.debug("Selected ticket: {s}", .{std.fmt.fmtSliceHexLower(&ticket.id)});

            // Look up the validator who created this ticket
            if (self.ticket_registry.lookupTicket(ticket.id)) |entry| {
                span.debug("Found ticket registry entry - validator: {d}, attempt: {d}", .{ entry.validator_index, entry.attempt });

                // Validate the entry index matches
                if (entry.attempt != ticket.attempt) {
                    span.err("Ticket attempt index mismatch entry.attempt {d} != ticket.attempt {d}", .{ entry.attempt, ticket.attempt });
                    return error.TicketAttemptMismatch;
                }

                return entry.validator_index;
            }
            // No valid author found
            span.err("Could not find validator ticket in the ticket_registry", .{});
            return error.ValidatorTicketNotFoundInRegistry;
        }

        fn selectBlockAuthorFromKeys(self: *Self, keys: []const types.BandersnatchPublic, slot_in_epoch: u64) !types.ValidatorIndex {
            const span = trace.span(.select_block_author_keys);
            defer span.deinit();
            span.debug("Using fallback key-based author selection for slot {d}", .{slot_in_epoch});

            // Validate inputs
            if (keys.len != params.epoch_length) {
                span.err("Invalid key count: expected {d}, got {d}", .{ params.validators_count, keys.len });
                return error.InvalidKeyCount;
            }
            if (slot_in_epoch >= params.epoch_length) {
                return error.InvalidSlotInEpoch;
            }

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
            // Additional bounds check for safety
            if (validator_index >= keys.len) {
                return error.InvalidValidatorIndex;
            }

            const validator_key = keys[validator_index];
            span.debug("Selected validator index {d} from key set", .{validator_index});
            span.trace("Using validator key: {any}", .{std.fmt.fmtSliceHexLower(&validator_key)});

            // TODO: ensure this is kappa'
            const found_index = try self.state.kappa.?.findValidatorIndex(.BandersnatchPublic, validator_key);
            span.trace("Found validator at kappa index: {d}", .{found_index});
            return found_index;
        }

        fn selectBlockAuthor(self: *Self, gamma_s_prime: types.GammaS) !types.ValidatorIndex {
            const span = trace.span(.select_block_author);
            defer span.deinit();
            span.debug("Selecting block author for slot {d}", .{self.block_time.current_slot});

            // Get index into gamma_s using current slot
            const slot_in_epoch = self.block_time.current_slot_in_epoch;
            span.debug("Slot in epoch: {d}", .{slot_in_epoch});

            // Validate slot is within epoch bounds
            if (slot_in_epoch >= params.epoch_length) {
                return error.InvalidSlotInEpoch;
            }

            // Select based on gamma_s mode
            return switch (gamma_s_prime) {
                .tickets => |tickets| try self.selectBlockAuthorFromTickets(tickets, slot_in_epoch),
                .keys => |keys| try self.selectBlockAuthorFromKeys(keys, slot_in_epoch),
            };
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
