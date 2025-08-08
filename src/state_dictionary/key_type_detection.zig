const std = @import("std");

/// Represents the different types of keys in the state dictionary
pub const DictKeyType = enum {
    state_component,
    delta_base,
    delta_service_data,
};

const types = @import("../types.zig");

/// Extracts service ID from an interleaved key format
fn extractServiceId(key: types.StateKey) u32 {
    var service_bytes: [4]u8 = undefined;
    service_bytes[0] = key[0];
    service_bytes[1] = key[2];
    service_bytes[2] = key[4];
    service_bytes[3] = key[6];
    return std.mem.readInt(u32, &service_bytes, .little);
}

/// De-interleaves the first 8 bytes of a key to get the original 4-byte pattern
fn deInterleavePrefix(key: types.StateKey) u32 {
    var prefix_bytes: [4]u8 = undefined;
    prefix_bytes[0] = key[1];
    prefix_bytes[1] = key[3];
    prefix_bytes[2] = key[5];
    prefix_bytes[3] = key[7];
    return std.mem.readInt(u32, &prefix_bytes, .little);
}

const deInterleaveServiceId = deInterleavePrefix;

pub fn detectKeyType(key: types.StateKey) DictKeyType {
    // State component keys still work
    if (key[0] >= 1 and key[0] <= 16) {
        var is_state_component = true;
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

    // Delta base still works
    if (key[0] == 255) {
        // Check the interleaving pattern
        if (key[2] == 0 and key[4] == 0 and key[6] == 0) {
            var is_delta_base = true;
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
    }

    // Everything else is some form of service data
    // We can't distinguish between storage/preimage/lookup anymore
    return .delta_service_data;
}
