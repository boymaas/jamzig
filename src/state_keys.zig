const std = @import("std");
const types = @import("types.zig");

// ============================================================================
// Base C function variants as per JAM graypaper D.1 (v0.6.7)
// ============================================================================

/// C function variant 1: i ∈ ℕ₂₈ → [i, 0, 0, ...]
/// For state component keys
fn C_variant1(i: u8) types.StateKey {
    var result: types.StateKey = [_]u8{0} ** 31;
    result[0] = i;
    return result;
}

/// C function variant 2: (i, s ∈ ℕS) → [i, n₀, 0, n₁, 0, n₂, 0, n₃, 0, 0, ...]
/// Where n = ℰ₄(s) (little-endian encoding of s)
/// For service base keys
fn C_variant2(i: u8, s: u32) types.StateKey {
    var result: types.StateKey = [_]u8{0} ** 31;

    // Encode s in little-endian (ℰ₄(s))
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);

    // Build the key: [i, n₀, 0, n₁, 0, n₂, 0, n₃, 0, 0, ...]
    result[0] = i;
    result[1] = n[0];
    result[2] = 0;
    result[3] = n[1];
    result[4] = 0;
    result[5] = n[2];
    result[6] = 0;
    result[7] = n[3];
    // Rest are already zeros

    return result;
}

/// C function variant 3 (v0.6.7): (s, h) → [n₀, a₀, n₁, a₁, n₂, a₂, n₃, a₃, a₄, a₅, ..., a₂₆]
/// Where n = ℰ₄(s) and a = ℋ(h)₀...₂₇
/// IMPORTANT: In v0.6.7, this variant now HASHES the input h first!
/// For interleaved keys with service ID and hashed data
fn C_variant3(s: u32, h: []const u8) types.StateKey {
    var result: types.StateKey = undefined;

    // NEW in v0.6.7: Hash the input first
    var a: [32]u8 = undefined;
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    hasher.update(h);
    hasher.final(&a);

    // Encode s in little-endian (ℰ₄(s))
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);

    // Interleave service ID bytes with first 4 bytes of a (the hash)
    result[0] = n[0];
    result[1] = a[0];
    result[2] = n[1];
    result[3] = a[1];
    result[4] = n[2];
    result[5] = a[2];
    result[6] = n[3];
    result[7] = a[3];

    // Copy remaining bytes from a (a₄...a₂₆)
    @memcpy(result[8..31], a[4..27]);

    return result;
}

// ============================================================================
// Public API functions built on top of C variants
// ============================================================================

/// Constructs a 31-byte key for state components (Alpha, Phi, Beta, etc.)
pub fn constructStateComponentKey(component_id: u8) types.StateKey {
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
pub fn constructStorageKey(service_id: u32, storage_key: []const u8) types.StateKey {
    // Prepare the data: ℰ₄(2³² - 1) ⌢ storage_key
    // REFACTOR: take an allocator or handle this differently
    var data = std.ArrayList(u8).init(std.heap.page_allocator);
    defer data.deinit();

    // ℰ₄(2³² - 1) = [255, 255, 255, 255] in little-endian
    var max_u32_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &max_u32_bytes, std.math.maxInt(u32), .little);
    data.appendSlice(&max_u32_bytes) catch unreachable;

    // Append the full storage key (not truncated)
    data.appendSlice(storage_key) catch unreachable;

    return C_variant3(service_id, data.items);
}

/// Constructs a 31-byte key for service base account metadata
pub fn constructServiceBaseKey(service_id: u32) types.StateKey {
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
pub fn constructServicePreimageKey(service_id: u32, hash: [32]u8) types.StateKey {
    // Prepare the data: ℰ₄(2³² - 2) ⌢ h
    var data: [36]u8 = undefined;

    // ℰ₄(2³² - 2) = [254, 255, 255, 255] in little-endian
    std.mem.writeInt(u32, data[0..4], std.math.maxInt(u32) - 1, .little);

    // Concatenate with the full hash
    @memcpy(data[4..36], &hash);

    return C_variant3(service_id, &data);
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
pub fn constructServicePreimageLookupKey(service_id: u32, length: u32, hash: [32]u8) types.StateKey {
    // Prepare the data: ℰ₄(l) ⌢ h
    var data: [36]u8 = undefined;

    // ℰ₄(l) - encode length in little-endian
    std.mem.writeInt(u32, data[0..4], length, .little);

    // Concatenate with the full hash
    @memcpy(data[4..36], &hash);

    return C_variant3(service_id, &data);
}
