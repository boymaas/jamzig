const std = @import("std");

pub const DictKeyType = enum {
    state_component,
    delta_base,
    delta_service_data,
};

const types = @import("../types.zig");

fn extractServiceId(key: types.StateKey) u32 {
    var service_bytes: [4]u8 = undefined;
    service_bytes[0] = key[0];
    service_bytes[1] = key[2];
    service_bytes[2] = key[4];
    service_bytes[3] = key[6];
    return std.mem.readInt(u32, &service_bytes, .little);
}

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

    if (key[0] == 255) {
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

    return .delta_service_data;
}
