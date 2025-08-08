const std = @import("std");
const types = @import("types.zig");

// ============================================================================
// Compile-time constants for optimization
// ============================================================================

// Pre-computed byte arrays for common values
const MAX_U32_BYTES = blk: {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, std.math.maxInt(u32), .little);
    break :blk bytes;
};

const MAX_U32_MINUS_1_BYTES = blk: {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, std.math.maxInt(u32) - 1, .little);
    break :blk bytes;
};

// ============================================================================
// Helper functions for optimization
// ============================================================================

/// Interleaves service ID bytes with hash bytes for C_variant3 output
/// This eliminates code duplication between C_variant3 and C_variant3_incremental
inline fn interleaveServiceAndHash(result: *types.StateKey, s: u32, hash: *const [32]u8) void {
    // Encode s in little-endian
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);
    
    // Interleave service ID bytes with first 4 bytes of hash
    result[0] = n[0];
    result[1] = hash[0];
    result[2] = n[1];
    result[3] = hash[1];
    result[4] = n[2];
    result[5] = hash[2];
    result[6] = n[3];
    result[7] = hash[3];
    
    // Copy remaining bytes from hash (a₄...a₂₆)
    @memcpy(result[8..31], hash[4..27]);
}

// ============================================================================
// Base C function variants as per JAM graypaper D.1 (v0.6.7)
// ============================================================================

/// C function variant 1: i ∈ ℕ₂₈ → [i, 0, 0, ...]
/// For state component keys
inline fn C_variant1(i: u8) types.StateKey {
    return .{i} ++ .{0} ** 30;
}

/// C function variant 2: (i, s ∈ ℕS) → [i, n₀, 0, n₁, 0, n₂, 0, n₃, 0, 0, ...]
/// Where n = ℰ₄(s) (little-endian encoding of s)
/// For service base keys
inline fn C_variant2(i: u8, s: u32) types.StateKey {
    var result: types.StateKey = [_]u8{0} ** 31;
    
    // Encode s in little-endian (ℰ₄(s))
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);
    
    result[0] = i;
    // Unrolled loop for better optimization
    inline for (0..4) |idx| {
        result[1 + idx * 2] = n[idx];
        // Zeros are already set from initialization
    }
    
    return result;
}

/// C function variant 3 (v0.6.7): (s, h) → [n₀, a₀, n₁, a₁, n₂, a₂, n₃, a₃, a₄, a₅, ..., a₂₆]
/// Where n = ℰ₄(s) and a = ℋ(h)₀...₂₇
/// IMPORTANT: In v0.6.7, this variant now HASHES the input h first!
/// For interleaved keys with service ID and hashed data
inline fn C_variant3(s: u32, h: []const u8) types.StateKey {
    var result: types.StateKey = undefined;
    
    // NEW in v0.6.7: Hash the input first
    var a: [32]u8 = undefined;
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    hasher.update(h);
    hasher.final(&a);
    
    interleaveServiceAndHash(&result, s, &a);
    return result;
}

/// C function variant 3 with incremental hashing: allows building the hash incrementally
/// to avoid allocations when concatenating data
inline fn C_variant3_incremental(s: u32, hasher: *std.crypto.hash.blake2.Blake2b256) types.StateKey {
    var result: types.StateKey = undefined;
    
    // Finalize the hash
    var a: [32]u8 = undefined;
    hasher.final(&a);
    
    interleaveServiceAndHash(&result, s, &a);
    return result;
}

// ============================================================================
// Public API functions built on top of C variants
// ============================================================================

/// Constructs a 31-byte key for state components (Alpha, Phi, Beta, etc.)
pub inline fn constructStateComponentKey(component_id: u8) types.StateKey {
    return C_variant1(component_id);
}

/// Constructs a 31-byte key for service storage operations per JAM graypaper v0.6.7
///
/// Uses C variant 3: C(s, ℰ₄(2³² - 1) ⌢ 𝐤)
/// Where 𝐤 is the raw storage key (any length)
/// The C function will hash this before using it
///
/// @param service_id - The service identifier
/// @param storage_key - The raw storage key (any length)
/// @return A 31-byte key for storage operations
pub inline fn constructStorageKey(service_id: u32, storage_key: []const u8) types.StateKey {
    // Build the hash incrementally without allocating
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    
    // Use pre-computed constant
    hasher.update(&MAX_U32_BYTES);
    
    // Append the full storage key (not truncated)
    hasher.update(storage_key);
    
    return C_variant3_incremental(service_id, &hasher);
}

/// Constructs a 31-byte key for service base account metadata
pub inline fn constructServiceBaseKey(service_id: u32) types.StateKey {
    return C_variant2(255, service_id);
}

/// Constructs a 31-byte key for service preimage entries per JAM graypaper v0.6.7
///
/// Uses C variant 3: C(s, ℰ₄(2³² - 2) ⌢ h)
/// Where h is the full 32-byte hash
/// The C function will hash this before using it
///
/// @param service_id - The service identifier
/// @param hash - The 32-byte Blake2b-256 hash of the preimage
/// @return A 31-byte key for the preimage entry
pub inline fn constructServicePreimageKey(service_id: u32, hash: [32]u8) types.StateKey {
    // Build the hash incrementally without allocating a temporary buffer
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    
    // Use pre-computed constant
    hasher.update(&MAX_U32_MINUS_1_BYTES);
    hasher.update(&hash);
    
    return C_variant3_incremental(service_id, &hasher);
}

/// Constructs a 31-byte key for service preimage lookup entries per JAM graypaper v0.6.7
///
/// Uses C variant 3: C(s, ℰ₄(l) ⌢ h)
/// Where l is the preimage length and h is the full hash
/// The C function will hash this before using it
///
/// @param service_id - The service identifier
/// @param length - The preimage length
/// @param hash - The 32-byte hash (typically Blake2b-256)
/// @return A 31-byte key for the preimage lookup entry
pub inline fn constructServicePreimageLookupKey(service_id: u32, length: u32, hash: [32]u8) types.StateKey {
    // Build the hash incrementally without allocating a temporary buffer
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    
    // ℰ₄(l) - encode length in little-endian
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, length, .little);
    
    hasher.update(&length_bytes);
    hasher.update(&hash);
    
    return C_variant3_incremental(service_id, &hasher);
}
