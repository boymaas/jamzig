const std = @import("std");

const utils = @import("merkle/utils.zig");

const types = @import("merkle/types.zig");

const Hash = types.Hash;
const Entry = ?Hash;

const MMR = std.ArrayList(Entry);

pub fn append(mrange: *MMR, leaf: Hash, hasher: anytype) !void {
    _ = try P(mrange, leaf, 0, hasher);
    return;
}

pub fn P(mrange: *MMR, leaf: Hash, n: usize, hasher: anytype) !*MMR {
    if (n >= mrange.items.len) {
        try mrange.append(leaf);
        return mrange;
    } else if (n < mrange.items.len and mrange.items[n] == null) {
        return R(mrange, n, leaf);
    } else {
        var H = hasher.init(.{});
        H.update(&mrange.items[n].?);
        H.update(&leaf);
        var hash_of_item_and_leaf: [32]u8 = undefined;
        H.final(&hash_of_item_and_leaf);
        return P(
            try R(mrange, n, null),
            hash_of_item_and_leaf,
            n + 1,
            hasher,
        );
    }
}

pub fn R(s: *MMR, i: usize, v: Entry) !*MMR {
    if (std.meta.eql(s.items[i], v)) {
        return s;
    }
    s.items[i] = v;
    return s;
}

const testing = std.testing;

test "mmr_append" {
    const allocator = std.testing.allocator;

    var mmr = MMR.init(allocator);
    defer mmr.deinit();

    const leaf1 = [_]u8{1} ** 32;
    const leaf2 = [_]u8{2} ** 32;
    const leaf3 = [_]u8{3} ** 32;

    const Blake2b_256 = std.crypto.hash.blake2.Blake2b(256);

    try append(&mmr, leaf1, Blake2b_256);
    try testing.expectEqual(@as(usize, 1), mmr.items.len);
    try testing.expectEqualSlices(u8, &leaf1, &mmr.items[0].?);

    try append(&mmr, leaf2, Blake2b_256);
    try testing.expectEqual(@as(usize, 2), mmr.items.len);
    try testing.expect(mmr.items[0] == null);

    try append(&mmr, leaf3, Blake2b_256);
    try testing.expectEqual(@as(usize, 2), mmr.items.len);
    try testing.expectEqualSlices(u8, &leaf3, &mmr.items[0].?);
}
