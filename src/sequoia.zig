const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const jam_params = @import("jam_params.zig");
const jamstate = @import("state.zig");

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
        current_slot: types.TimeSlot,
        last_header_hash: ?types.Hash,
        last_state_root: ?types.Hash,

        pub fn init(allocator: std.mem.Allocator, initial_state: *jamstate.JamState(params)) !Self {
            var validator_keys = try allocator.alloc(ValidatorKeySet, params.validators_count);
            errdefer allocator.free(validator_keys);

            // Needs to be initalized
            try Bls12_381.init();

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

        pub fn buildNextBlock(self: *Self) !types.Block {
            const author_index = try self.selectBlockProducer();
            const author_keys = self.validator_keys[author_index];

            // Generate entropy signature for fallback mode
            const entropy_vrf_sig = try self.generateEntropySignature(author_keys.bandersnatch_keypair);

            // Generate block seal for fallback mode
            const block_seal = try self.generateBlockSeal(author_keys.bandersnatch_keypair);

            const header = types.Header{
                .parent = if (self.last_header_hash) |hash| hash else std.mem.zeroes(types.Hash),
                .parent_state_root = if (self.last_state_root) |root| root else std.mem.zeroes(types.Hash),
                .extrinsic_hash = std.mem.zeroes(types.Hash),
                .slot = self.current_slot,
                .author_index = author_index,
                .epoch_mark = null,
                .tickets_mark = null,
                .offenders_mark = &[_]types.Ed25519Public{},
                .entropy_source = entropy_vrf_sig,
                .seal = block_seal,
            };

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

            const block = types.Block{
                .header = header,
                .extrinsic = extrinsic,
            };

            self.current_slot += 1;
            self.last_header_hash = try block.header.header_hash(params, self.allocator);

            // try self.state.merge(block); // Update state with new block
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

        fn generateEntropySignature(self: *Self, keypair: bandersnatch.BandersnatchKeyPair) !types.BandersnatchVrfSignature {
            _ = self;
            _ = keypair;
            // TODO: Implement proper VRF signing
            return std.mem.zeroes(types.BandersnatchVrfSignature);
        }

        fn generateBlockSeal(self: *Self, keypair: bandersnatch.BandersnatchKeyPair) !types.BandersnatchVrfSignature {
            _ = self;
            _ = keypair;
            // TODO: Implement proper block sealing
            return std.mem.zeroes(types.BandersnatchVrfSignature);
        }
    };
}

pub fn createTinyBlockBuilder(
    allocator: std.mem.Allocator,
    initial_state: *jamstate.JamState(jam_params.TINY_PARAMS),
) !BlockBuilder(jam_params.TINY_PARAMS) {
    return BlockBuilder(jam_params.TINY_PARAMS).init(allocator, initial_state);
}
