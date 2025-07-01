const std = @import("std");
const types = @import("types.zig");

// ============================================================================
// Base C function variants as per JAM graypaper D.1
// ============================================================================

/// C function variant 1: i ∈ ℕ₂₈ → [i, 0, 0, ...]
/// For state component keys
fn C_variant1(i: u8) types.StateKey {
    var result: types.StateKey = [_]u8{0} ** 31;
    result[0] = i;
    return result;
}

/// C function variant 2: (i, s ∈ ℕ₈) → [i, n₀, 0, n₁, 0, n₂, 0, n₃, 0, 0, ...]
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

/// C function variant 3: (s, h) → [n₀, h₀, n₁, h₁, n₂, h₂, n₃, h₃, h₄, h₅, ..., h₂₆]
/// Where n = ℰ₄(s) (little-endian encoding of s)
/// For interleaved keys with service ID and data
fn C_variant3(s: u32, h: []const u8) types.StateKey {
    var result: types.StateKey = undefined;

    // Encode s in little-endian (ℰ₄(s))
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);

    // Interleave service ID bytes with first 4 bytes of h
    result[0] = n[0];
    result[1] = if (h.len > 0) h[0] else 0;
    result[2] = n[1];
    result[3] = if (h.len > 1) h[1] else 0;
    result[4] = n[2];
    result[5] = if (h.len > 2) h[2] else 0;
    result[6] = n[3];
    result[7] = if (h.len > 3) h[3] else 0;

    // Copy remaining bytes from h (up to position 27, giving us h₄...h₂₆)
    const remaining_start = 8;
    const remaining_h_start = 4;
    const remaining_len = @min(h.len -| remaining_h_start, 31 - remaining_start);

    if (remaining_len > 0) {
        @memcpy(result[remaining_start..][0..remaining_len], h[remaining_h_start..][0..remaining_len]);
    }

    // Fill any remaining bytes with zeros
    if (remaining_start + remaining_len < 31) {
        @memset(result[remaining_start + remaining_len .. 31], 0);
    }

    return result;
}

// ============================================================================
// Public API functions built on top of C variants
// ============================================================================

/// Constructs a 31-byte key for state components (Alpha, Phi, Beta, etc.)
///
/// Uses C variant 1: i ∈ ℕ₂₈ → [i, 0, 0, ...]
/// Used for JAM state components 1-15 in the merklization dictionary.
///
/// @param component_id - The state component identifier (1-15)
/// @return A 31-byte key for the state component
pub fn constructStateComponentKey(component_id: u8) types.StateKey {
    return C_variant1(component_id);
}

/// Constructs a 31-byte key for service storage operations per JAM graypaper
///
/// Uses C variant 3: C(s, ℰ₄(2³² - 1) ⌢ h₀...₂₇)
/// Where h₀...₂₇ are the first 28 bytes of the provided hash
///
/// @param service_id - The service identifier
/// @param key_data - The 32-byte hash (e.g., Blake2b-256 of the PVM key data)
/// @return A 31-byte key for storage operations
pub fn constructStorageKey(service_id: u32, key_data: [32]u8) types.StateKey {
    // Prepare the data: ℰ₄(2³² - 1) ⌢ h₀...₂₇
    var data: [32]u8 = undefined;

    // ℰ₄(2³² - 1) = [255, 255, 255, 255] in little-endian
    std.mem.writeInt(u32, data[0..4], std.math.maxInt(u32), .little);

    // Concatenate with first 28 bytes of the hash
    @memcpy(data[4..32], key_data[0..28]);

    return C_variant3(service_id, &data);
}

/// Constructs a 31-byte key for service base account metadata
///
/// Uses C variant 2: C(255, s)
/// Format: [255, n₀, 0, n₁, 0, n₂, 0, n₃, 0, 0, ..., 0]
/// Where n₀-n₃ are service ID bytes (little-endian)
///
/// @param service_id - The service identifier
/// @return A 31-byte key for the service base account data
pub fn constructServiceBaseKey(service_id: u32) types.StateKey {
    return C_variant2(255, service_id);
}

//  ____                  _          ____           _
// / ___|  ___ _ ____   _(_) ___ ___ |  _ \ _ __ ___(_)_ __ ___   __ _  __ _  ___
// \___ \ / _ \ '__\ \ / / |/ __/ _ \| |_) | '__/ _ \ | '_ ` _ \ / _` |/ _` |/ _ \
//  ___) |  __/ |   \ V /| | (_|  __/|  __/| | |  __/ | | | | | | (_| | (_| |  __/
// |____/ \___|_|    \_/ |_|\___\___||_|   |_|  \___|_|_| |_| |_|\__,_|\__, |\___|
//                                                                     |___/

/// Constructs a 31-byte key for service preimage entries
///
/// Uses C variant 3: C(s, ℰ₄(2³² - 2) ⌢ h₁...₂₈)
/// Where h₁...₂₈ are bytes 1-28 of the Blake2b-256 hash
///
/// @param service_id - The service identifier
/// @param hash - The 32-byte Blake2b-256 hash of the preimage
/// @return A 31-byte key for the preimage entry
pub fn constructServicePreimageKey(service_id: u32, hash: [32]u8) types.StateKey {
    // Prepare the data: ℰ₄(2³² - 2) ⌢ h₁...₂₈
    var data: [32]u8 = undefined;

    // ℰ₄(2³² - 2) = [254, 255, 255, 255] in little-endian
    std.mem.writeInt(u32, data[0..4], std.math.maxInt(u32) - 1, .little);

    // Concatenate with h₁...₂₈ (bytes 1-28 of the hash)
    @memcpy(data[4..32], hash[1..29]);

    return C_variant3(service_id, &data);
}

/// Constructs a 31-byte key for service preimage lookup entries
///
/// Uses C variant 3: C(s, ℰ₄(l) ⌢ ℋ(h)₂...₂₉)
/// Where l is the preimage length and ℋ(h)₂...₂₉ are bytes 2-29 of the hash
///
/// @param service_id - The service identifier
/// @param length - The preimage length
/// @param hash - The 32-byte hash (typically Blake2b-256)
/// @return A 31-byte key for the preimage lookup entry
pub fn constructServicePreimageLookupKey(service_id: u32, length: u32, hash: [32]u8) types.StateKey {
    // Prepare the data: ℰ₄(l) ⌢ ℋ(h)₂...₂₉
    var data: [32]u8 = undefined;

    // ℰ₄(l) - encode length in little-endian
    std.mem.writeInt(u32, data[0..4], length, .little);

    // Concatenate with ℋ(h)₂...₂₉ (bytes 2-29 of the hash)
    @memcpy(data[4..32], hash[2..30]);

    return C_variant3(service_id, &data);
}

