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
    // Branch node: first bit 0
    result[0] = l[0] & 0b01111111;
    // Use last 255 bits of left sub-trie
    @memcpy(result[1..32], l[1..]);
    // Use full 256 bits of right sub-trie
    @memcpy(result[32..], &r);
    return result;
}

fn leaf(k: Key, v: []const u8) [64]u8 {
    var result: [64]u8 = undefined;
    if (v.len <= 32) {
        // Embedded value leaf: first bit 1, second bit 0
        // Next 6 bits store value size
        result[0] = 0b10000000 | (@as(u8, @truncate(v.len)) & 0x3f);
        // 31 bytes for key prefix
        @memcpy(result[1..32], k[0..31]);
        // Up to 32 bytes for value, zero-padded
        @memcpy(result[32..][0..v.len], v);
        @memset(result[32 + v.len ..][0..], 0);
    } else {
        // Regular leaf: first bit 1, second bit 1
        // Next 6 bits zeroed
        result[0] = 0b11000000;
        // 31 bytes for key prefix
        @memcpy(result[1..32], k[0..31]);
        // 32 bytes for value hash
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

    // Partition the array in-place based on the bit at position i
    while (left < right) {
        // Find a 1-bit from the left
        while (left < right and !bit(kvs[left].k, i)) : (left += 1) {}
        // Find a 0-bit from the right
        while (left < right and bit(kvs[right].k, i)) : (right -= 1) {}

        if (left < right) {
            // Swap elements
            const temp = kvs[left];
            kvs[left] = kvs[right];
            kvs[right] = temp;
        }
    }

    // Return the partition point (first 1-bit position)
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

    // Find the division point
    const split = partition(kvs, i);

    // Recursively process left and right partitions
    const ml = merkle(kvs[0..split], i + 1);
    const mr = merkle(kvs[split..], i + 1);

    // Combine results
    const encoded = branch(ml, mr);
    var result: Hash = undefined;
    Blake2b256.hash(&encoded, &result, .{});
    return result;
}

pub fn M_sigma(kvs: []Entry) Hash {
    return merkle(kvs, 0);
}
