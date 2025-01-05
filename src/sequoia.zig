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

        // Registry of tickets mapping ticket IDs to validator indices & entry indices
        const TicketRegistryEntry = struct {
            validator_index: types.ValidatorIndex,
            entry_index: u8,
        };

        config: GenesisConfig(params),

        allocator: std.mem.Allocator,
        state: jamstate.JamState(params),
        current_slot: types.TimeSlot = 0,

        last_header_hash: ?types.Hash,
        last_state_root: ?types.Hash,

        rng: *std.Random,

        validator_tickets: [params.validators_count]u8,

        // Within a block authoring epoch, block production privileges are granted based on tickets that were submitted in the
        // prior epoch. These tickets use anonymous ring signature proofs, so while everyone can verify tickets came from valid
        // validators, only the original submitters know which tickets are theirs. Therefore we maintain a local registry mapping
        // each ticket ID to its creator, allowing us to recover the correct block author when one of their tickets is selected.
        // TODO: rename with _epoch
        ticket_registry_previous: std.AutoHashMap(types.OpaqueHash, TicketRegistryEntry),
        ticket_registry_current: std.AutoHashMap(types.OpaqueHash, TicketRegistryEntry),

        /// Initialize the BlockBuilder with required state
        pub fn init(
            allocator: std.mem.Allocator,
            config: GenesisConfig(params),
            rng: *std.Random,
        ) !Self {
            // Initialize registry
            const registry_current = std.AutoHashMap(types.OpaqueHash, TicketRegistryEntry).init(allocator);
            const registry_previous = std.AutoHashMap(types.OpaqueHash, TicketRegistryEntry).init(allocator);

            return Self{
                .allocator = allocator,
                .config = config,
                .state = try config.buildJamState(allocator, rng),
                .current_slot = config.initial_slot,
                .last_header_hash = null,
                .last_state_root = null,
                .rng = rng,
                .validator_tickets = std.mem.zeroes([params.validators_count]u8),
                .ticket_registry_current = registry_current,
                .ticket_registry_previous = registry_previous,
            };
        }

        pub fn deinit(self: *Self) void {
            self.config.deinit(self.allocator);
            self.state.deinit(self.allocator);
            self.ticket_registry_current.deinit();
            self.ticket_registry_previous.deinit();
        }

        fn generateVrfOutputFallback(author_keys: *const ValidatorKeySet, eta_prime: *const types.Eta) !types.BandersnatchVrfOutput {
            const span = trace.span(.generate_vrf_output_fallback);
            defer span.deinit();
            span.debug("Generating VRF output using fallback function", .{});

            const context = "jam_fallback_seal" ++ eta_prime[3];
            span.trace("Using eta_prime[3]: {any}", .{std.fmt.fmtSliceHexLower(&eta_prime[3])});
            span.trace("Using context: {s}", .{context});

            span.debug("Signing with Bandersnatch keypair", .{});
            span.trace("Using public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});
            const signature = try author_keys.bandersnatch_keypair
                .sign(&[_]u8{}, context);
            span.trace("Generated signature: {s}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

            const output = try signature.outputHash();
            span.debug("Generated VRF output", .{});
            span.trace("VRF output: {s}", .{std.fmt.fmtSliceHexLower(&output)});

            return output;
        }

        fn generateEntropySourceFallback(
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
                .sign(&[_]u8{}, context);

            span.debug("Generated entropy source signature", .{});
            span.trace("Entropy source bytes: {any}", .{std.fmt.fmtSliceHexLower(&entropy_source.toBytes())});

            return entropy_source;
        }

        /// Generate the block seal signature using either ticket or fallback mode
        fn generateBlockSealFallback(
            allocator: std.mem.Allocator,
            header: *const types.Header, // Assumes entropy_source is already set
            author_keys: ValidatorKeySet,
            eta_prime: *const types.Eta,
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
                .sign(header_unsigned, context);

            span.debug("Generated block seal signature", .{});
            span.trace("Seal signature bytes: {any}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

            return signature;
        }

        fn generateEntropySourceTicket(
            author_keys: ValidatorKeySet,
            ticket: types.TicketBody,
        ) !Bandersnatch.Signature {
            const span = trace.span(.generate_entropy_source_ticket);
            defer span.deinit();
            span.debug("Generating entropy source using fallback method", .{});

            // Now sign with our Bandersnatch keypair
            const context = "jam_entropy" ++ ticket.id;
            span.trace("Signing context: {s}", .{context});
            span.trace("Using public key: {any}", .{std.fmt.fmtSliceHexLower(&author_keys.bandersnatch_keypair.public_key.toBytes())});

            span.debug("Generating Bandersnatch signature", .{});
            const entropy_source = try author_keys.bandersnatch_keypair
                .sign(&[_]u8{}, context);

            span.debug("Generated entropy source signature", .{});
            span.trace("Entropy source bytes: {any}", .{std.fmt.fmtSliceHexLower(&entropy_source.toBytes())});

            return entropy_source;
        }

        /// Generate the block seal signature using either ticket or fallback mode
        fn generateBlockSealTickets(
            allocator: std.mem.Allocator,
            header: *const types.Header, // Assumes entropy_source is already set
            author_keys: ValidatorKeySet,
            eta_prime: *const types.Eta,
            ticket: types.TicketBody,
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
                .sign(header_unsigned, context);

            span.debug("Generated block seal signature", .{});
            span.trace("Seal signature bytes: {any}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});

            return signature;
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

            // TODO: add an config option to skip slots, simulating failing or delayed block production

            const previous_epoch = self.current_slot / params.epoch_length;
            const previous_slot_position = self.current_slot & params.epoch_length;

            // Ensure new slot is greater than parent
            const new_slot = @max(
                self.current_slot + 1,
                self.state.tau.? + 1,
            );
            self.current_slot = new_slot;

            const current_epoch = self.current_slot / params.epoch_length;
            const current_epoch_slot = self.current_slot % params.epoch_length;

            // Header's epoch marker (He): empty, or for first block in epoch:
            // - Next epoch randomness
            // - Current epoch randomness
            // - Next epoch's Bandersnatch validator keys
            var epoch_mark: ?types.EpochMark = null;
            if (current_epoch > previous_epoch) {
                epoch_mark = .{
                    .entropy = self.state.eta.?[0],
                    .tickets_entropy = self.state.eta.?[1],
                    .validators = try self.state.gamma.?.k.getBandersnatchPublicKeys(self.allocator), // TODO: this has to be gamma_k_prime
                };
            }

            var tickets_mark: ?types.TicketsMark = null;
            if (current_epoch == previous_epoch //
            and current_epoch_slot > params.ticket_submission_end_epoch_slot //
            and previous_slot_position <= params.ticket_submission_end_epoch_slot //
            and self.state.gamma.?.a.len == params.epoch_length //
            ) {
                // TODO: untested, need ticket submission first
                tickets_mark = .{ .tickets = try safrole.Z_outsideInOrdering(types.TicketBody, self.allocator, self.state.gamma.?.a) };
            }

            const entropy_source = switch (self.state.gamma.?.s) {
                .tickets => |tickets| try generateEntropySourceTicket(author_keys, tickets[current_epoch_slot]),
                .keys => try generateEntropySourceFallback(author_keys, &self.state.eta.?),
            };

            // TODO: Get eta_prime for this slot
            const eta_current = &self.state.eta.?;
            var eta_prime = self.state.eta.?;
            if (current_epoch > previous_epoch) {
                // Rotate the entropy values
                eta_prime[3] = eta_current[2];
                eta_prime[2] = eta_current[1];
                eta_prime[1] = eta_current[0];
            }
            eta_prime[0] = @import("entropy.zig").update(self.state.eta.?[0], try entropy_source.outputHash());

            // Create initial header without signatures
            var header = types.Header{
                .parent = if (self.last_header_hash) |hash| hash else std.mem.zeroes(types.Hash),
                .parent_state_root = if (self.last_state_root) |root| root else std.mem.zeroes(types.Hash),
                .extrinsic_hash = std.mem.zeroes(types.Hash),
                .slot = self.current_slot,
                .author_index = author_index,
                .epoch_mark = epoch_mark,
                .tickets_mark = tickets_mark,
                .offenders_mark = &[_]types.Ed25519Public{},
                .entropy_source = entropy_source.toBytes(),
                .seal = undefined,
            };

            // Generate block seal
            const block_seal = switch (self.state.gamma.?.s) {
                .keys => try generateBlockSealFallback(
                    self.allocator,
                    &header,
                    author_keys,
                    &eta_prime,
                ),
                .tickets => |tickets| try generateBlockSealTickets(
                    self.allocator,
                    &header,
                    author_keys,
                    &eta_prime,
                    tickets[current_epoch_slot],
                ),
            };
            header.seal = block_seal.toBytes();

            if (current_epoch > previous_epoch) {
                // Swap ticket registry maps, and clear the current one
                span.debug("New epoch - swapping ticket registries and clearing current one", .{});
                const previous = self.ticket_registry_previous;
                self.ticket_registry_previous = self.ticket_registry_current;
                self.ticket_registry_current = previous;
                self.ticket_registry_current.clearRetainingCapacity();
            }

            var tickets = types.TicketsExtrinsic{ .data = &[_]types.TicketEnvelope{} };
            if (current_epoch_slot < params.ticket_submission_end_epoch_slot) {
                tickets = .{ .data = try self.generateTickets(&eta_prime) }; // TODO: eta_prime
            } else {
                span.debug("Outside ticket submission period", .{});
            }

            // Reset ticket counts at epoch boundary, next blocks validators
            // will be able to submit tickets
            if (current_epoch > previous_epoch) {
                span.debug("New epoch - resetting validator ticket counts", .{});
                self.validator_tickets = std.mem.zeroes([params.validators_count]u8);
            }

            const extrinsic = types.Extrinsic{
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

            // Assemble complete block
            const block = types.Block{
                .header = header,
                .extrinsic = extrinsic,
            };

            // Update block history
            self.last_header_hash = try block.header.header_hash(params, self.allocator);
            self.last_state_root = try self.state.buildStateRoot(self.allocator);

            span.trace("block:\n{s}", .{types.fmt.format(&block)});

            return block;
        }

        const GeneratedTicket = struct {
            envelope: types.TicketEnvelope,
            id: types.OpaqueHash,
        };

        fn generateTickets(
            self: *Self,
            eta_prime: *const types.Eta,
        ) ![]types.TicketEnvelope {
            const span = trace.span(.generate_tickets);
            defer span.deinit();
            span.debug("Generating tickets", .{});

            var generated = std.ArrayList(GeneratedTicket).init(self.allocator);
            defer generated.deinit();

            const gamma_k_keys = try self.state.gamma.?.k.getBandersnatchPublicKeys(self.allocator);
            defer self.allocator.free(gamma_k_keys);

            // For each validator, randomly decide if they submit a ticket this block
            for (self.config.validator_keys, 0..) |validator, idx| {
                // Skip if validator already submitted max tickets
                if (self.validator_tickets[idx] >= params.max_ticket_entries_per_validator) {
                    span.trace("Validator {d} already submitted max tickets", .{idx});
                    continue;
                }

                // ~20% chance to submit a ticket per block if eligible
                if (self.rng.intRangeAtMost(u8, 0, 10) < 5) {
                    span.debug("Generating ticket for validator {d}", .{idx});

                    // Create prover for this validator
                    var prover = try ring_vrf.RingProver.init(
                        validator.bandersnatch_keypair.secret_key.toBytes(),
                        gamma_k_keys,
                        idx,
                    );
                    defer prover.deinit();

                    // Sign with prover to generate ticket
                    const entry_idx = self.validator_tickets[idx];
                    const vrf_input = "jam_ticket_seal" ++ eta_prime[2] ++ [_]u8{entry_idx};
                    const vrf_proof = try prover.sign(
                        vrf_input,
                        &[_]u8{},
                    );

                    span.trace("Ticket generation values:", .{});
                    span.trace("  Validator index: {d}", .{idx});
                    span.trace("  Attempt number: {d}", .{entry_idx});

                    span.trace("  Ring size: {d}", .{params.validators_count});
                    span.trace("  Ring values:", .{});
                    span.trace("    Gamma_z: {s}", .{std.fmt.fmtSliceHexLower(&self.state.gamma.?.z)});
                    span.trace("  VRF input:", .{});
                    span.trace("    Context: {s}", .{vrf_input});
                    span.trace("    Eta[2]: {s}", .{std.fmt.fmtSliceHexLower(&eta_prime[2])});
                    span.trace("  VRF output:", .{});
                    span.trace("    Proof: {s}", .{std.fmt.fmtSliceHexLower(&vrf_proof)});
                    span.trace("    Public key: {s}", .{std.fmt.fmtSliceHexLower(&validator.bandersnatch_keypair.public_key.toBytes())});

                    const ticket_id = try ring_vrf.verifyRingSignatureAgainstCommitment(
                        &self.state.gamma.?.z,
                        params.validators_count,
                        vrf_input,
                        &[_]u8{},
                        &vrf_proof,
                    );
                    span.trace("  Ticket ID: {s}", .{std.fmt.fmtSliceHexLower(&ticket_id)});

                    // Create and append ticket
                    const ticket = types.TicketEnvelope{
                        .attempt = entry_idx,
                        .signature = vrf_proof,
                    };
                    try generated.append(.{ .envelope = ticket, .id = ticket_id });

                    // After creating the ticket and getting its ID:
                    try self.ticket_registry_current.put(ticket_id, .{
                        .validator_index = try self.state.kappa.?.findValidatorIndex(.BandersnatchPublic, validator.bandersnatch_keypair.public_key.toBytes()),
                        .entry_index = entry_idx,
                    });

                    // Increment ticket count for this validator
                    self.validator_tickets[idx] += 1;

                    // Only include up to K tickets per block
                    if (generated.items.len >= params.max_ticket_entries_per_validator) {
                        span.debug("Reached max tickets per block ({d})", .{params.max_ticket_entries_per_validator});
                        break;
                    }
                }
            }

            // Sort tickets by VRF output (ticket identifier)
            // TODO: most effective algo?
            if (generated.items.len > 0) {
                span.debug("Sorting {d} tickets by VRF output", .{generated.items.len});
                std.sort.insertion(
                    GeneratedTicket,
                    generated.items,
                    {},
                    struct {
                        pub fn lessThan(_: void, a: GeneratedTicket, b: GeneratedTicket) bool {
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

            // Get ticket for this slot
            const ticket = tickets[slot_in_epoch];

            // Look up the validator who created this ticket
            if (self.ticket_registry_previous.get(ticket.id)) |registry_entry| {
                span.debug("Found ticket registry entry - validator: {d}, attempt: {d}", .{ registry_entry.validator_index, registry_entry.entry_index });

                // Validate the entry index matches
                if (registry_entry.entry_index == ticket.attempt) {
                    span.err("Ticket attempt index mismatch", .{});
                    return registry_entry.validator_index;
                }
            }

            // No valid author found
            span.err("No validator found for ticket", .{});
            return error.NoValidatorFound;
        }

        fn selectBlockAuthorFromKeys(self: *Self, keys: []const types.BandersnatchPublic, slot_in_epoch: u64) !types.ValidatorIndex {
            const span = trace.span(.select_block_author_keys);
            defer span.deinit();
            span.debug("Using fallback key-based author selection for slot {d}", .{slot_in_epoch});

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
            const found_index = try self.state.kappa.?.findValidatorIndex(.BandersnatchPublic, validator_key);
            span.trace("Found validator at kappa index: {d}", .{found_index});
            return found_index;
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
                return switch (gamma.s) {
                    .tickets => |tickets| try self.selectBlockAuthorFromTickets(tickets, slot_in_epoch),
                    .keys => |keys| try self.selectBlockAuthorFromKeys(keys, slot_in_epoch),
                };
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
