// TODO: rename to bandersnatch

const std = @import("std");
const types = @import("types.zig");

// Extern declarations for Rust functions
pub extern fn create_key_pair_from_seed(
    seed: [*c]const u8,
    seed_len: usize,
    output: [*c]u8,
) callconv(.C) bool;

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

pub extern fn get_padding_point(
    ring_size: usize,
    output: [*c]u8,
) callconv(.C) bool;

pub fn getPaddingPoint(ring_size: usize) !types.BandersnatchPublic {
    var output: types.BandersnatchPublic = undefined;
    const result = get_padding_point(
        ring_size,
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
