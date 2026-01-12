const std = @import("std");
const types = @import("types.zig");

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

inline fn interleaveServiceAndHash(result: *types.StateKey, s: u32, hash: *const [32]u8) void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);

    result[0] = n[0];
    result[1] = hash[0];
    result[2] = n[1];
    result[3] = hash[1];
    result[4] = n[2];
    result[5] = hash[2];
    result[6] = n[3];
    result[7] = hash[3];

    @memcpy(result[8..31], hash[4..27]);
}

inline fn C_variant1(i: u8) types.StateKey {
    return .{i} ++ .{0} ** 30;
}

inline fn C_variant2(i: u8, s: u32) types.StateKey {
    var result: types.StateKey = [_]u8{0} ** 31;

    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, s, .little);

    result[0] = i;
    inline for (0..4) |idx| {
        result[1 + idx * 2] = n[idx];
    }

    return result;
}

inline fn C_variant3(s: u32, h: []const u8) types.StateKey {
    var result: types.StateKey = undefined;

    var a: [32]u8 = undefined;
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    hasher.update(h);
    hasher.final(&a);

    interleaveServiceAndHash(&result, s, &a);
    return result;
}

inline fn C_variant3_incremental(s: u32, hasher: *std.crypto.hash.blake2.Blake2b256) types.StateKey {
    var result: types.StateKey = undefined;

    var a: [32]u8 = undefined;
    hasher.final(&a);

    interleaveServiceAndHash(&result, s, &a);
    return result;
}

pub inline fn constructStateComponentKey(component_id: u8) types.StateKey {
    return C_variant1(component_id);
}

pub inline fn constructStorageKey(service_id: u32, storage_key: []const u8) types.StateKey {
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});

    hasher.update(&MAX_U32_BYTES);
    hasher.update(storage_key);

    return C_variant3_incremental(service_id, &hasher);
}

pub inline fn constructServiceBaseKey(service_id: u32) types.StateKey {
    return C_variant2(255, service_id);
}

pub inline fn constructServicePreimageKey(service_id: u32, hash: [32]u8) types.StateKey {
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});

    hasher.update(&MAX_U32_MINUS_1_BYTES);
    hasher.update(&hash);

    return C_variant3_incremental(service_id, &hasher);
}

pub inline fn constructServicePreimageLookupKey(service_id: u32, length: u32, hash: [32]u8) types.StateKey {
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});

    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, length, .little);

    hasher.update(&length_bytes);
    hasher.update(&hash);

    return C_variant3_incremental(service_id, &hasher);
}
