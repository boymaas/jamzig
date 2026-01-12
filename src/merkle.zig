const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);
const types = @import("merkle/types.zig");
const Key = types.Key;
const Hash = types.Hash;

pub const Entry = struct {
    k: Key,
    v: []const u8,
};

fn branch(l: Hash, r: Hash) [64]u8 {
    var result: [64]u8 = undefined;
    result[0] = l[0] & 0b01111111;
    @memcpy(result[1..32], l[1..]);
    @memcpy(result[32..], &r);
    return result;
}

fn leaf(k: Key, v: []const u8) [64]u8 {
    var result: [64]u8 = undefined;
    if (v.len <= 32) {
        result[0] = 0b10000000 | (@as(u8, @truncate(v.len)) & 0x3f);
        @memcpy(result[1..32], k[0..31]);
        @memcpy(result[32..][0..v.len], v);
        @memset(result[32 + v.len ..][0..], 0);
    } else {
        result[0] = 0b11000000;
        @memcpy(result[1..32], k[0..31]);
        Blake2b256.hash(v, result[32..64], .{});
    }
    return result;
}

fn bit(k: Key, i: usize) bool {
    return (k[i >> 3] & (@as(u8, 0x80) >> @intCast(i & 7))) != 0;
}

fn partition(kvs: []Entry, i: usize) usize {
    if (kvs.len <= 1) return 0;

    var left: usize = 0;
    var right: usize = kvs.len - 1;

    while (left < right) {
        while (left < right and !bit(kvs[left].k, i)) : (left += 1) {}
        while (left < right and bit(kvs[right].k, i)) : (right -= 1) {}

        if (left < right) {
            const temp = kvs[left];
            kvs[left] = kvs[right];
            kvs[right] = temp;
        }
    }

    while (left < kvs.len and !bit(kvs[left].k, i)) : (left += 1) {}
    return left;
}

fn merkle(kvs: []Entry, i: usize) Hash {
    if (kvs.len == 0) {
        return [_]u8{0} ** 32;
    }
    if (kvs.len == 1) {
        const encoded = leaf(kvs[0].k, kvs[0].v);
        var result: Hash = undefined;
        Blake2b256.hash(&encoded, &result, .{});
        return result;
    }

    const split = partition(kvs, i);

    const ml = merkle(kvs[0..split], i + 1);
    const mr = merkle(kvs[split..], i + 1);

    const encoded = branch(ml, mr);
    var result: Hash = undefined;
    Blake2b256.hash(&encoded, &result, .{});
    return result;
}

pub fn jamMerkleRoot(kvs: []Entry) Hash {
    return merkle(kvs, 0);
}
