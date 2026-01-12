const std = @import("std");
const types = @import("types.zig");

pub const KeyType = enum {
    state_component,
    service_base,
    service_storage,
    service_preimage,
    service_preimage_lookup,
    unknown,
};

/// Extract service ID from any service-related 31-byte key
/// Returns null if not a service-related key
pub fn extractServiceIdFromKey(key: types.StateKey) ?u32 {
    if (key[0] >= 1 and key[0] <= 15 and key[1] == 0 and key[2] == 0) {
        return null;
    }

    const service_bytes = [4]u8{
        key[0],
        key[2],
        key[4],
        key[6],
    };

    return std.mem.readInt(u32, &service_bytes, .little);
}

/// Detect the type of a 31-byte key
pub fn detectKeyType(key: types.StateKey) KeyType {
    if (key[0] >= 1 and key[0] <= 15 and key[1] == 0 and key[2] == 0 and key[3] == 0) {
        return .state_component;
    }

    if (key[0] != 0 and key[1] != 0 and key[2] == 255 and key[4] == 255 and key[6] == 255) {
        return .service_base;
    }

    if (extractServiceIdFromKey(key) != null) {
        return .service_storage;
    }

    return .unknown;
}

/// Legacy compatibility function for state reconstruction
/// Extracts service index from old-style service base keys
/// TEMPORARY: Used during transition period
pub fn deconstructByteServiceIndexKey(key: types.StateKey) struct { byte: u8, service_index: u32 } {
    const service_bytes = [4]u8{
        key[1],
        key[3],
        key[5],
        key[7],
    };

    return .{
        .byte = key[0],
        .service_index = std.mem.readInt(u32, &service_bytes, .little),
    };
}

/// Legacy compatibility function for hash-based keys
/// TEMPORARY: Used during transition period
pub fn deconstructServiceIndexHashKey(key: types.StateKey) struct { service_index: u32, hash: LossyHash(27) } {
    var hash: [27]u8 = undefined;

    const service_bytes = [4]u8{
        key[0],
        key[2],
        key[4],
        key[6],
    };
    const service_index = std.mem.readInt(u32, &service_bytes, .little);

    hash[0] = key[1];
    hash[1] = key[3];
    hash[2] = key[5];
    hash[3] = key[7];
    @memcpy(hash[4..], key[8..]);

    return .{
        .service_index = service_index,
        .hash = .{ .hash = hash, .start = 0, .end = 27 },
    };
}

/// Legacy lossy hash type for compatibility
/// TEMPORARY: Used during transition period
pub fn LossyHash(comptime size: usize) type {
    return struct {
        hash: [size]u8,
        start: usize,
        end: usize,
        
        pub fn matches(self: *const @This(), other: *const [32]u8) bool {
            return std.mem.eql(u8, &self.hash, other[self.start..self.end]);
        }
    };
}

//  _   _ _   _ _         _____         _   
// | | | | |_(_) |_      |_   _|__  ___| |_ 
// | | | | __| | | |_____ | |/ _ \/ __| __|
// | |_| | |_| | | |_____|| |  __/\__ \ |_ 
//  \___/ \__|_|_|_|      |_|\___||___/\__|

const testing = std.testing;

test "extractServiceIdFromKey" {
    // Test state component key (should return null)
    const state_key = [_]u8{5} ++ [_]u8{0} ** 30;
    try testing.expectEqual(@as(?u32, null), extractServiceIdFromKey(state_key));
    
    // Test service key with service ID 0x12345678
    var service_key: types.StateKey = [_]u8{0} ** 31;
    service_key[0] = 0x78; // service_id byte 0
    service_key[2] = 0x56; // service_id byte 1
    service_key[4] = 0x34; // service_id byte 2
    service_key[6] = 0x12; // service_id byte 3
    
    try testing.expectEqual(@as(?u32, 0x12345678), extractServiceIdFromKey(service_key));
}

test "detectKeyType" {
    // Test state component key
    const state_key = [_]u8{5} ++ [_]u8{0} ** 30;
    try testing.expectEqual(KeyType.state_component, detectKeyType(state_key));
    
    // Test service base key
    var base_key: types.StateKey = [_]u8{0} ** 31;
    base_key[0] = 255;
    base_key[1] = 0x78;
    base_key[2] = 255;
    base_key[3] = 0x56;
    base_key[4] = 255;
    base_key[5] = 0x34;
    base_key[6] = 255;
    base_key[7] = 0x12;
    
    try testing.expectEqual(KeyType.service_base, detectKeyType(base_key));
}

test "deconstructByteServiceIndexKey" {
    // Create a service base key
    var key: types.StateKey = [_]u8{0} ** 31;
    key[0] = 255; // Service base marker
    key[1] = 0x78; // service_id byte 0
    key[3] = 0x56; // service_id byte 1  
    key[5] = 0x34; // service_id byte 2
    key[7] = 0x12; // service_id byte 3
    
    const result = deconstructByteServiceIndexKey(key);
    try testing.expectEqual(@as(u8, 255), result.byte);
    try testing.expectEqual(@as(u32, 0x12345678), result.service_index);
}