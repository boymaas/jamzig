const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const ring_vrf = @import("ring_vrf.zig");
const jam_params = @import("jam_params.zig");
const jamstate = @import("state.zig");
const codec = @import("codec.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Bls12_381 = crypto.bls.Bls12_381;
const bandersnatch = crypto.bandersnatch;

const ValidatorKeySet = struct {
    bandersnatch_keypair: bandersnatch.BandersnatchKeyPair,
    ed25519_keypair: Ed25519.KeyPair,
    bls12_381_keypair: Bls12_381.KeyPair,

    const SEED_LENGTH = 32;

    pub fn init(seed: [SEED_LENGTH]u8) !ValidatorKeySet {
        return ValidatorKeySet{
            .bandersnatch_keypair = try bandersnatch.createKeyPairFromSeed(&seed),
            .ed25519_keypair = try Ed25519.KeyPair.create(seed),
            .bls12_381_keypair = try Bls12_381.KeyPair.create(seed),
        };
    }
};

pub fn BlockBuilder(comptime params: jam_params.Params) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        state: *jamstate.JamState(params),
        validator_keys: []ValidatorKeySet,
        current_slot: types.TimeSlot = 0,

        last_header_hash: ?types.Hash,
        last_state_root: ?types.Hash,

        /// Initialize the BlockBuilder with required state
        pub fn init(allocator: std.mem.Allocator, initial_state: *jamstate.JamState(params)) !Self {
            var validator_keys = try allocator.alloc(ValidatorKeySet, params.validators_count);
            errdefer allocator.free(validator_keys);

            // Initialize BLS for cryptographic operations
            try Bls12_381.init();

            // Generate validator keys from deterministic seeds
            for (0..params.validators_count) |i| {
                var seed: [32]u8 = [_]u8{0} ** ValidatorKeySet.SEED_LENGTH;
                std.mem.writeInt(u32, seed[0..4], @as(u32, @intCast(i)), .little);
                validator_keys[i] = try ValidatorKeySet.init(seed);
            }

            return Self{
                .allocator = allocator,
                .state = initial_state,
                .validator_keys = validator_keys,
                .current_slot = 0,
                .last_header_hash = null,
                .last_state_root = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.validator_keys);
        }

        /// Check if ticket-based sealing is possible for the current slot
        fn canUseTicketSealing(self: *Self, _: types.ValidatorIndex) bool {
            if (self.state.gamma) |gamma| {
                // Check the GammaS component which holds either tickets or keys
                switch (gamma.s) {
                    .tickets => |tickets| {
                        // Calculate slot within epoch
                        const slot_in_epoch = self.current_slot % params.epoch_length;
                        // Check if there's a valid ticket for this slot
                        return tickets[slot_in_epoch].id[0] != 0;
                    },
                    .keys => return false, // In fallback mode, can't use tickets
                }
            }
            return false;
        }

        /// Generate the block seal signature using either ticket or fallback mode
        fn generateBlockSeal(
            self: *Self,
            header: *const types.Header,
            author_keys: ValidatorKeySet,
            validator_set: types.ValidatorSet,
            use_ticket: bool,
        ) !types.BandersnatchVrfSignature {
            var message = std.ArrayList(u8).init(self.allocator);
            defer message.deinit();

            if (use_ticket) {
                // Ticket-based sealing
                try message.appendSlice("jam_ticket_seal");
                if (self.state.eta) |eta| {
                    try message.appendSlice(eta[2][0..3]); // Use 3 bytes from current entropy
                }
            } else {
                // Fallback sealing
                try message.appendSlice("jam_fallback_seal");

                // Hash header and append to message
                var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
                const encoded_header_unsigned = try codec.serializeAlloc(
                    types.HeaderUnsigned,
                    params,
                    self.allocator,
                    types.HeaderUnsigned.fromHeaderShared(header),
                );
                defer self.allocator.free(encoded_header_unsigned);
                hasher.update(encoded_header_unsigned);

                var hash: [32]u8 = undefined;
                hasher.final(&hash);
                try message.appendSlice(&hash);
            }

            // TODO: we are doing this twice move this to outer scope, same with findValidatorIndex
            const pubkeys = try validator_set.getBandersnatchPublicKeys(self.allocator);
            defer self.allocator.free(pubkeys);

            // Create VRF prover with the author's key
            var prover = try ring_vrf.RingProver.init(
                author_keys.bandersnatch_keypair.private_key,
                pubkeys,
                try validator_set.findValidatorIndex(.BandersnatchPublic, author_keys.bandersnatch_keypair.public_key),
            );
            defer prover.deinit();

            // Generate and return the seal signature
            return try prover.signIetf(message.items, &[_]u8{});
        }

        /// Generate the VRF entropy signature using the seal output
        fn generateEntropySignature(
            self: *Self,
            seal_output: types.BandersnatchVrfSignature,
            author_keys: ValidatorKeySet,
            validator_set: types.ValidatorSet,
        ) !types.BandersnatchVrfSignature {
            var message = std.ArrayList(u8).init(self.allocator);
            defer message.deinit();

            // Construct entropy message
            try message.appendSlice("jam_entropy");
            try message.appendSlice(&seal_output);

            const pub_keys = try validator_set.getBandersnatchPublicKeys(self.allocator);
            defer self.allocator.free(pub_keys);

            // Create VRF prover
            var prover = try ring_vrf.RingProver.init(
                author_keys.bandersnatch_keypair.private_key,
                pub_keys,
                try validator_set.findValidatorIndex(
                    .BandersnatchPublic,
                    author_keys.bandersnatch_keypair.public_key,
                ),
            );
            defer prover.deinit();

            // Generate and return entropy signature
            return try prover.signIetf(message.items, &[_]u8{});
        }

        /// Build the next block in the chain with proper sealing
        pub fn buildNextBlock(self: *Self) !types.Block {
            // Select block producer for this slot
            const author_index = try self.selectBlockProducer();
            const author_keys = self.validator_keys[author_index];

            // Determine if we can use ticket-based sealing
            const use_ticket = self.canUseTicketSealing(author_index);

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
                self.state.kappa.?,
                use_ticket,
            );

            // Generate entropy signature using seal output
            header.entropy_source = try self.generateEntropySignature(
                header.seal,
                author_keys,
                self.state.kappa.?,
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

        fn selectBlockProducer(self: *Self) !types.ValidatorIndex {
            // const slot = self.current_slot;
            const entropy = if (self.state.eta) |eta| eta[2] else std.mem.zeroes(types.Entropy);

            // Convert entropy bytes to u64 and use it to select validator
            const entropy_int = std.mem.readInt(u64, entropy[0..8], .big);
            const index = @as(types.ValidatorIndex, @truncate(entropy_int % params.validators_count));
            return index;
        }
    };
}

pub fn createTinyBlockBuilder(
    allocator: std.mem.Allocator,
    initial_state: *jamstate.JamState(jam_params.TINY_PARAMS),
) !BlockBuilder(jam_params.TINY_PARAMS) {
    return BlockBuilder(jam_params.TINY_PARAMS).init(allocator, initial_state);
}
