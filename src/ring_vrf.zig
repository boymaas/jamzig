const std = @import("std");
const types = @import("types.zig");

// Opaque types for the Rust objects
const Verifier = opaque {};
const Prover = opaque {};

pub const Error = error{
    VerifierCreationFailed,
    ProverCreationFailed,
    SigningFailed,
    VerificationFailed,
    GetCommitmentFailed,
    SignatureVerificationFailed,
};

//  ____
// |  _ \ _ __ _____   _____ _ __
// | |_) | '__/ _ \ \ / / _ \ '__|
// |  __/| | | (_) \ V /  __/ |
// |_|   |_|  \___/ \_/ \___|_|
//

extern fn new_ring_vrf_prover(
    secret: [*]const u8,
    public_keys: [*]const u8,
    public_keys_len: usize,
    prover_idx: usize,
) ?*Prover;

extern fn vrf_sign(
    prover: *const Prover,
    vrf_input_data: [*]const u8,
    vrf_input_data_len: usize,
    aux_data: [*]const u8,
    aux_data_len: usize,
    signature_out: [*]u8,
    signature_size_out: *usize,
) bool;

extern fn ietf_vrf_sign(
    prover: *const Prover,
    vrf_input_data: [*]const u8,
    vrf_input_data_len: usize,
    aux_data: [*]const u8,
    aux_data_len: usize,
    signature_out: [*]u8,
    signature_size_out: *usize,
) bool;

extern fn free_ring_vrf_prover(prover: *Prover) void;

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
        self.* = undefined;
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

    pub fn signIetf(
        self: *const RingProver,
        vrf_input: []const u8,
        aux_data: []const u8,
    ) Error!types.BandersnatchIetfVrfSignature {
        var signature: types.BandersnatchIetfVrfSignature = undefined;
        var signature_size: usize = 0;

        const success = ietf_vrf_sign(
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

        std.debug.assert(signature_size == @sizeOf(types.BandersnatchIetfVrfSignature));
        return signature;
    }
};

// __     __        _  __ _
// \ \   / /__ _ __(_)/ _(_) ___ _ __
//  \ \ / / _ \ '__| | |_| |/ _ \ '__|
//   \ V /  __/ |  | |  _| |  __/ |
//    \_/ \___|_|  |_|_| |_|\___|_|
//

// FFI declarations
extern fn new_ring_vrf_verifier(
    public_keys: [*]const u8,
    public_keys_len: usize,
) ?*Verifier;

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

extern fn ietf_vrf_verify(
    verifier: *const Verifier,
    vrf_input_data: [*]const u8,
    vrf_input_data_len: usize,
    aux_data: [*]const u8,
    aux_data_len: usize,
    signature: [*]const u8,
    signature_len: usize,
    signer_key_index: usize,
    output: [*]u8,
    output_len: *usize,
) bool;

extern fn vrf_get_commitment(
    verifier: *const Verifier,
    output: [*]u8,
) bool;

extern fn free_ring_vrf_verifier(verifier: *Verifier) void;

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
        self.* = undefined;
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

    pub fn verifyIetf(
        self: *const RingVerifier,
        vrf_input: []const u8,
        aux_data: []const u8,
        signature: *const types.BandersnatchIetfVrfSignature,
        signer_key_index: usize,
    ) Error!types.BandersnatchVrfOutput {
        var output: types.BandersnatchVrfOutput = undefined;
        var output_len: usize = 0;

        const success = ietf_vrf_verify(
            self.ptr,
            vrf_input.ptr,
            vrf_input.len,
            aux_data.ptr,
            aux_data.len,
            @ptrCast(signature),
            @sizeOf(types.BandersnatchIetfVrfSignature), // adjust if variable sized
            signer_key_index,
            &output,
            &output_len,
        );

        if (!success) {
            return Error.VerificationFailed;
        }

        // If the output is always exactly 32 bytes, you can assert here:
        // std.debug.assert(output_len == 32);
        return output;
    }

    pub fn get_commitment(self: *const RingVerifier) Error!types.BandersnatchVrfRoot {
        var output: types.BandersnatchVrfRoot = undefined;
        if (!vrf_get_commitment(self.ptr, &output)) {
            return Error.GetCommitmentFailed;
        }

        return output;
    }
};

//   ____                          _ _                        _
//  / ___|___  _ __ ___  _ __ ___ (_) |_ _ __ ___   ___ _ __ | |_ ___
// | |   / _ \| '_ ` _ \| '_ ` _ \| | __| '_ ` _ \ / _ \ '_ \| __/ __|
// | |__| (_) | | | | | | | | | | | | |_| | | | | |  __/ | | | |_\__ \
//  \____\___/|_| |_| |_|_| |_| |_|_|\__|_| |_| |_|\___|_| |_|\__|___/

extern fn vrf_verify_ring_signature_against_commitment(
    commitment: [*c]const u8,
    ring_size: usize,
    vrf_input_data: [*c]const u8,
    vrf_input_len: usize,
    aux_data: [*c]const u8,
    aux_data_len: usize,
    signature: [*c]const u8,
    vrf_output: [*c]u8,
) callconv(.C) bool;

pub fn verifyRingSignatureAgainstCommitment(
    commitment: *const types.BandersnatchVrfRoot,
    ring_size: usize,
    vrf_input: []const u8,
    aux_data: []const u8,
    signature: *const types.BandersnatchRingVrfSignature,
) Error!types.BandersnatchVrfOutput {
    var vrf_output: types.BandersnatchVrfOutput = undefined;

    const result = vrf_verify_ring_signature_against_commitment(
        @ptrCast(commitment),
        ring_size,
        @ptrCast(vrf_input.ptr),
        vrf_input.len,
        @ptrCast(aux_data.ptr),
        aux_data.len,
        @ptrCast(signature),
        @ptrCast(&vrf_output),
    );

    if (!result) {
        return Error.SignatureVerificationFailed;
    }

    return vrf_output;
}

//  ____           _     _ _             ____       _       _
// |  _ \ __ _  __| | __| (_)_ __   __ _|  _ \ ___ (_)_ __ | |_
// | |_) / _` |/ _` |/ _` | | '_ \ / _` | |_) / _ \| | '_ \| __|
// |  __/ (_| | (_| | (_| | | | | | (_| |  __/ (_) | | | | | |_
// |_|   \__,_|\__,_|\__,_|_|_| |_|\__, |_|   \___/|_|_| |_|\__|
//                                 |___/

extern fn get_padding_point(
    ring_size: usize,
    output: [*]u8,
) bool;

pub fn getPaddingPoint(ring_size: usize) Error!types.BandersnatchPublic {
    var point: types.BandersnatchPublic = undefined;

    const success = get_padding_point(
        ring_size,
        @ptrCast(&point),
    );

    if (!success) {
        return Error.GetCommitmentFailed;
    }

    return point;
}

test "ring_vrf.padding: get padding point" {
    const ring_size: usize = 5;
    const padding_point = try getPaddingPoint(ring_size);
    std.debug.print("Padding point for ring size {d}: {any}\n", .{ ring_size, std.fmt.fmtSliceHexLower(&padding_point) });
}

//  _   _       _ _     _____         _
// | | | |_ __ (_) |_  |_   _|__  ___| |_ ___
// | | | | '_ \| | __|   | |/ _ \/ __| __/ __|
// | |_| | | | | | |_    | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__|   |_|\___||___/\__|___/
//

const bandersnatch = @import("crypto/bandersnatch.zig");

test "ring_vrf.basic: basic usage" {
    const ring_size: usize = 5;
    var public_keys: [ring_size]types.BandersnatchPublic = undefined;

    // Generate some test public keys
    for (0..ring_size) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try bandersnatch.Bandersnatch.KeyPair.generateDeterministic(seed);
        public_keys[i] = key_pair.public_key.toBytes();
    }

    // Create verifier
    var verifier = try RingVerifier.init(&public_keys);
    defer verifier.deinit();

    // Create prover
    const prover_idx = 2;
    const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_idx));
    const key_pair = try bandersnatch.Bandersnatch.KeyPair.generateDeterministic(seed);
    var prover = try RingProver.init(
        key_pair.secret_key.toBytes(),
        &public_keys,
        prover_idx,
    );
    defer prover.deinit();

    // Test signing and verification
    const vrf_input = "test input";
    const aux_data = "test aux data";

    const signature = try prover.sign(vrf_input, aux_data);
    _ = try verifier.verify(vrf_input, aux_data, &signature);

    // Test getting commitment
    _ = try verifier.get_commitment();
}

test "ring_vrf.ietf: IETF VRF usage" {
    const ring_size: usize = 5;
    var public_keys: [ring_size]types.BandersnatchPublic = undefined;

    // Generate some test public keys
    for (0..ring_size) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try bandersnatch.Bandersnatch.KeyPair.generateDeterministic(seed);
        public_keys[i] = key_pair.public_key.toBytes();
    }

    // Create verifier
    var verifier = try RingVerifier.init(&public_keys);
    defer verifier.deinit();

    // Create prover
    const prover_idx = 2;
    const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_idx));
    const key_pair = try bandersnatch.Bandersnatch.KeyPair.generateDeterministic(seed);
    var prover = try RingProver.init(key_pair.secret_key.toBytes(), &public_keys, prover_idx);
    defer prover.deinit();

    // Test signing and verification (IETF VRF)
    const vrf_input = "ietf test input";
    const aux_data = "ietf aux data";

    // 1. IETF VRF sign
    const ietf_signature = try prover.signIetf(vrf_input, aux_data);

    // 2. IETF VRF verify
    //    You typically need to specify which ring index is the actual signer
    const signer_key_index = prover_idx;
    const vrf_output = try verifier.verifyIetf(vrf_input, aux_data, &ietf_signature, signer_key_index);

    std.debug.print("IETF VRF signature: {x}\n", .{ietf_signature});
    std.debug.print("IETF VRF output: {x}\n", .{vrf_output});
}
