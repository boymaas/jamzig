const std = @import("std");

/// Represents the different types of keys in the state dictionary
pub const DictKeyType = enum {
    state_component, // State components (1-15)
    delta_base, // Service base info (255)
    delta_storage, // Service storage entries
    delta_preimage, // Service preimage entries
    delta_preimage_lookup, // Service preimage lookup entries
    unknown,
};

/// Extracts service ID from an interleaved key format
fn extractServiceId(key: [32]u8) u32 {
    var service_bytes: [4]u8 = undefined;
    service_bytes[0] = key[0];
    service_bytes[1] = key[2];
    service_bytes[2] = key[4];
    service_bytes[3] = key[6];
    return std.mem.readInt(u32, &service_bytes, .little);
}

/// De-interleaves the first 8 bytes of a key to get the original 4-byte pattern
fn deInterleavePrefix(key: [32]u8) u32 {
    var prefix_bytes: [4]u8 = undefined;
    prefix_bytes[0] = key[1];
    prefix_bytes[1] = key[3];
    prefix_bytes[2] = key[5];
    prefix_bytes[3] = key[7];
    return std.mem.readInt(u32, &prefix_bytes, .little);
}

const deInterleaveServiceId = deInterleavePrefix;

/// Determines the type of a state dictionary key
pub fn detectKeyType(key: [32]u8) DictKeyType {
    // First check for simple state component keys (1-15 followed by zeros)
    if (key[0] >= 1 and key[0] <= 15) {
        var is_state_component = true;
        // Verify remaining bytes are zero
        for (key[1..]) |byte| {
            if (byte != 0) {
                is_state_component = false;
                break;
            }
        }
        if (is_state_component) {
            return .state_component;
        }
    }

    // Check for delta base (255)
    if (key[0] == 255) {
        var is_delta_base = true;
        // Verify the interleaving pattern for service index
        const service_id = deInterleaveServiceId(key);
        _ = service_id; // This can me any number
        // Check if service_id is non-zero and all other bytes after first 8 are zero

        // Verify remaining bytes are zero (skip first 8 bytes which contain service_id)
        // Check if bytes 2,4,6 are 0
        if (key[2] != 0 or key[4] != 0 or key[6] != 0) {
            is_delta_base = false;
        }
        // Check remaining bytes after service id
        for (key[8..]) |byte| {
            if (byte != 0) {
                is_delta_base = false;
                break;
            }
        }
        if (is_delta_base) {
            return .delta_base;
        }
    }

    // For remaining types, de-interleave the prefix to check the pattern
    const prefix = deInterleavePrefix(key);

    // Check service storage/preimage/lookup patterns
    switch (prefix) {
        0xFFFFFFFF => return .delta_storage,
        0xFFFFFFFE => return .delta_preimage,
        else => {
            // For preimage lookup, the prefix should be a valid length value
            // Typically this would be less than some maximum value
            // Let's assume a reasonable maximum length for preimages
            return .delta_preimage_lookup;
        },
    }
}

test "detectKeyType simple state" {
    const testing = std.testing;

    // Test simple state key
    var simple_key = [_]u8{0} ** 32;
    simple_key[0] = 5;
    try testing.expectEqual(detectKeyType(simple_key), .state_component);
}

test "detectKeyType delta base" {
    const testing = std.testing;

    // Test delta base key
    var base_key = [_]u8{0} ** 32;
    base_key[0] = 255;
    base_key[1] = 42;
    base_key[3] = 42;
    base_key[5] = 42;
    base_key[7] = 42;
    try testing.expectEqual(detectKeyType(base_key), .delta_base);
}

test "detectKeyType service entries" {
    const testing = std.testing;

    var key = [_]u8{0} ** 32;

    // Test storage key
    key[1] = 0xFF;
    key[3] = 0xFF;
    key[5] = 0xFF;
    key[7] = 0xFF;
    try testing.expectEqual(detectKeyType(key), .delta_storage);

    // Test preimage key
    key[1] = 0xFE;
    key[3] = 0xFF;
    key[5] = 0xFF;
    key[7] = 0xFF;
    try testing.expectEqual(detectKeyType(key), .delta_preimage);

    // Test lookup key
    key[1] = 0x10; // length = 16
    key[3] = 0x00;
    key[5] = 0x00;
    key[7] = 0x00;
    try testing.expectEqual(detectKeyType(key), .delta_lookup);
}
