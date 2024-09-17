const std = @import("std");
const types = @import("types.zig");

// Extern declarations for Rust functions
extern fn generate_ring_signature(
    public_keys: [*c]const u8,
    public_keys_len: usize,
    vrf_input_data: [*c]const u8,
    vrf_input_len: usize,
    aux_data: [*c]const u8,
    aux_data_len: usize,
    prover_idx: usize,
    prover_key: [*c]const u8,
    output: [*c]u8,
) callconv(.C) bool;

extern fn verify_ring_signature(
    public_keys: [*c]const u8,
    public_keys_len: usize,
    vrf_input_data: [*c]const u8,
    vrf_input_len: usize,
    aux_data: [*c]const u8,
    aux_data_len: usize,
    signature: [*c]const u8,
    vrf_output: [*c]u8,
) callconv(.C) bool;

// Extern declarations for Rust functions
pub extern fn create_key_pair_from_seed(
    seed: [*c]const u8,
    seed_len: usize,
    output: [*c]u8,
) callconv(.C) bool;

pub extern fn get_padding_point(
    output: [*c]u8,
) callconv(.C) bool;

// Zig wrapper functions
pub fn generateRingSignature(
    public_keys: []const types.BandersnatchKey,
    vrf_input: []const u8,
    aux_data: []const u8,
    prover_idx: usize,
    prover_key: types.BandersnatchKey,
) !types.BandersnatchRingSignature {
    var output: types.BandersnatchRingSignature = undefined;
    const result = generate_ring_signature(
        @ptrCast(public_keys.ptr),
        public_keys.len,
        @ptrCast(vrf_input.ptr),
        vrf_input.len,
        @ptrCast(aux_data.ptr),
        aux_data.len,
        prover_idx,
        @ptrCast(&prover_key),
        &output,
    );

    if (!result) {
        return error.SignatureGenerationFailed;
    }

    return output;
}

pub fn verifyRingSignature(
    public_keys: []types.BandersnatchKey,
    vrf_input: []const u8,
    aux_data: []const u8,
    signature: *const types.BandersnatchRingSignature,
) !types.BandersnatchVrfOutput {
    var vrf_output: types.BandersnatchVrfOutput = undefined;

    const result = verify_ring_signature(
        @ptrCast(public_keys.ptr),
        public_keys.len,
        @ptrCast(vrf_input.ptr),
        vrf_input.len,
        @ptrCast(aux_data.ptr),
        aux_data.len,
        @ptrCast(signature),
        @ptrCast(&vrf_output),
    );

    if (!result) {
        return error.SignatureVerificationFailed;
    }

    return vrf_output;
}

// Helper functions
pub fn createKeyPairFromSeed(seed: []const u8) !types.BandersnatchKeyPair {
    var output: [64]u8 = undefined;
    const result = create_key_pair_from_seed(
        seed.ptr,
        seed.len,
        &output,
    );

    if (!result) {
        return error.KeyPairGenerationFailed;
    }

    // Split the output into private and public keys
    var key_pair: types.BandersnatchKeyPair = undefined;
    @memcpy(&key_pair.private_key, output[0..32]);
    @memcpy(&key_pair.public_key, output[32..64]);

    return key_pair;
}

pub fn getPaddingPoint() !types.BandersnatchKey {
    var output: types.BandersnatchKey = undefined;
    const result = get_padding_point(
        &output,
    );

    if (!result) {
        return error.PaddingPointGenerationFailed;
    }

    return output;
}

test "crypto: createKeyPairFromSeed" {
    const seed = "test seed for key pair generation";
    const key_pair = try createKeyPairFromSeed(seed);

    // Verify that the key pair is not empty
    try std.testing.expect(key_pair.private_key.len == 32);
    try std.testing.expect(key_pair.public_key.len == 32);

    // Verify that the private and public keys are different
    try std.testing.expect(!std.mem.eql(u8, &key_pair.private_key, &key_pair.public_key));

    // Verify that generating a key pair with the same seed produces the same result
    const key_pair2 = try createKeyPairFromSeed(seed);
    try std.testing.expect(std.mem.eql(u8, &key_pair.private_key, &key_pair2.private_key));
    try std.testing.expect(std.mem.eql(u8, &key_pair.public_key, &key_pair2.public_key));

    // Print the key_pair
    std.debug.print("Private key: ", .{});
    for (key_pair.private_key) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    std.debug.print("Public key: {s}\n", .{std.fmt.fmtSliceHexLower(&key_pair.public_key)});
}

test "crypto: ring signature and VRF" {
    const RING_SIZE: usize = 10;
    var ring: [RING_SIZE]types.BandersnatchKey = undefined;

    // Generate public keys for the ring
    for (0..RING_SIZE) |i| {
        const seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, i));
        const key_pair = try createKeyPairFromSeed(seed);
        ring[i] = key_pair.public_key;

        // Print the first 3 keys in hex format
        if (i < 3) {
            std.debug.print("Public key {}: ", .{i});
            for (key_pair.public_key) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
        }
    }

    const prover_key_index: usize = 3;

    // Generate a key pair for the prover
    const prover_seed = std.mem.asBytes(&std.mem.nativeToLittle(usize, prover_key_index));
    const prover_key_pair = try createKeyPairFromSeed(prover_seed);

    std.debug.print("Secret key length: {} bytes\n", .{prover_key_pair.private_key.len});
    std.debug.print("Public key length: {} bytes\n", .{prover_key_pair.public_key.len});

    // Replace some keys with padding points
    // const padding_point = try getPaddingPoint();
    // ring[2] = padding_point;
    // ring[7] = padding_point;

    const vrf_input_data = [_]u8{ 'f', 'o', 'o' };
    const aux_data = [_]u8{ 'b', 'a', 'r' };

    // Generate ring signature
    const ring_signature = try generateRingSignature(&ring, &vrf_input_data, &aux_data, prover_key_index, prover_key_pair.private_key);
    std.debug.print("Ring signature length: {} bytes\n", .{ring_signature.len});
    std.debug.print("Ring signature: ", .{});
    for (ring_signature) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    // Verify ring signature
    const ring_vrf_output = try verifyRingSignature(&ring, &vrf_input_data, &aux_data, &ring_signature);
    std.debug.print("Ring VRF output length: {} bytes\n", .{ring_vrf_output.len});
    std.debug.print("Ring VRF output: ", .{});
    for (ring_vrf_output) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}
