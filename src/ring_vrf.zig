const std = @import("std");
const types = @import("types.zig");

// Opaque types for the Rust objects
const Verifier = opaque {};
const Prover = opaque {};

// FFI declarations
extern fn new_ring_vrf_verifier(
    public_keys: [*]const u8,
    public_keys_len: usize,
) ?*Verifier;

extern fn free_ring_vrf_verifier(verifier: *Verifier) void;

extern fn new_ring_vrf_prover(
    secret: [*]const u8,
    public_keys: [*]const u8,
    public_keys_len: usize,
    prover_idx: usize,
) ?*Prover;

extern fn free_ring_vrf_prover(prover: *Prover) void;

extern fn vrf_sign(
    prover: *const Prover,
    vrf_input_data: [*]const u8,
    vrf_input_data_len: usize,
    aux_data: [*]const u8,
    aux_data_len: usize,
    signature_out: [*]u8,
    signature_size_out: *usize,
) bool;

extern fn vrf_verify(
    verifier: *const Verifier,
    vrf_input_data: [*]const u8,
    vrf_input_data_len: usize,
    aux_data: [*]const u8,
    aux_data_len: usize,
    signature: [*]const u8,
    signature_len: usize,
    output_hash_out: [*]u8,
) bool;

pub const Error = error{
    VerifierCreationFailed,
    ProverCreationFailed,
    SigningFailed,
    VerificationFailed,
};

pub const RingVerifier = struct {
    ptr: *Verifier,

    pub fn init(public_keys: []const types.BandersnatchPublic) Error!RingVerifier {
        const ptr = new_ring_vrf_verifier(
            @ptrCast(public_keys.ptr),
            public_keys.len * @sizeOf(types.BandersnatchPublic),
        ) orelse return Error.VerifierCreationFailed;

        return RingVerifier{ .ptr = ptr };
    }

    pub fn deinit(self: *RingVerifier) void {
        free_ring_vrf_verifier(self.ptr);
    }

    pub fn verify(
        self: *const RingVerifier,
        vrf_input: []const u8,
        aux_data: []const u8,
        signature: *const types.BandersnatchRingVrfSignature,
    ) Error!types.BandersnatchVrfOutput {
        var output: types.BandersnatchVrfOutput = undefined;

        const success = vrf_verify(
            self.ptr,
            vrf_input.ptr,
            vrf_input.len,
            aux_data.ptr,
            aux_data.len,
            @ptrCast(signature),
            @sizeOf(types.BandersnatchRingVrfSignature),
            &output,
        );

        if (!success) {
            return Error.VerificationFailed;
        }

        return output;
    }
};

pub const RingProver = struct {
    ptr: *Prover,

    pub fn init(
        secret: types.BandersnatchPublic,
        public_keys: []const types.BandersnatchPublic,
        prover_idx: usize,
    ) Error!RingProver {
        const ptr = new_ring_vrf_prover(
            @ptrCast(&secret),
            @ptrCast(public_keys.ptr),
            public_keys.len * @sizeOf(types.BandersnatchPublic),
            prover_idx,
        ) orelse return Error.ProverCreationFailed;

        return RingProver{ .ptr = ptr };
    }

    pub fn deinit(self: *RingProver) void {
        free_ring_vrf_prover(self.ptr);
    }

    pub fn sign(
        self: *const RingProver,
        vrf_input: []const u8,
        aux_data: []const u8,
    ) Error!types.BandersnatchRingVrfSignature {
        var signature: types.BandersnatchRingVrfSignature = undefined;
        var signature_size: usize = undefined;

        const success = vrf_sign(
            self.ptr,
            vrf_input.ptr,
            vrf_input.len,
            aux_data.ptr,
            aux_data.len,
            @ptrCast(&signature),
            &signature_size,
        );

        if (!success) {
            return Error.SigningFailed;
        }

        std.debug.assert(signature_size == @sizeOf(types.BandersnatchRingVrfSignature));
        return signature;
    }
};

test "ring_vrf: basic usage" {
    const ring_size: usize = 5;
    var public_keys: [ring_size]types.BandersnatchPublic = undefined;

    // Generate some test public keys
    for (0..ring_size) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try @import("crypto.zig").createKeyPairFromSeed(seed);
        public_keys[i] = key_pair.public_key;
    }

    // Create verifier
    var verifier = try RingVerifier.init(&public_keys);
    defer verifier.deinit();

    // Create prover
    const prover_idx = 2;
    const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_idx));
    const key_pair = try @import("crypto.zig").createKeyPairFromSeed(seed);
    var prover = try RingProver.init(key_pair.private_key, &public_keys, prover_idx);
    defer prover.deinit();

    // Test signing and verification
    const vrf_input = "test input";
    const aux_data = "test aux data";

    const signature = try prover.sign(vrf_input, aux_data);
    _ = try verifier.verify(vrf_input, aux_data, &signature);
}
