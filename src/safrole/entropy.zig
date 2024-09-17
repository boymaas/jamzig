const std = @import("std");

const Blake2b_256 = std.crypto.hash.blake2.Blake2b(256);

// Hashing function (Blake2b)
pub fn hash(input: []const u8) [32]u8 {
    var hasher = Blake2b_256.init(.{});
    hasher.update(input);
    var output: [32]u8 = undefined;
    hasher.final(&output);
    return output;
}

// Function to concatenate two byte arrays
pub fn concatenate(a: [32]u8, b: [32]u8) [64]u8 {
    var result: [64]u8 = undefined;
    @memcpy(result[0..32], &a);
    @memcpy(result[32..], &b);
    return result;
}

/// The entropy update function
/// (66) η′0 ≡H(η0 ⌢ Y(Hv))
pub fn update(eta0: [32]u8, Hv: [32]u8) [32]u8 {
    // Concatenate η0 and Y(Hv)
    const concatenated = concatenate(eta0, Hv);

    // Hash the concatenated result to produce the new entropy η'0
    const new_eta0 = hash(&concatenated);

    return new_eta0;
}
