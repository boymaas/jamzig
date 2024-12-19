const std = @import("std");

const utils = @import("merkle/utils.zig");

const types = @import("merkle/types.zig");

const Hash = types.Hash;
const Entry = ?Hash;

pub const MMR = std.ArrayList(Entry);

pub fn filter_nulls(mrange: []const Entry, buffer: []Hash) []Hash {
    var count: usize = 0;
    for (mrange) |maybe_hash| {
        if (maybe_hash) |hash| {
            buffer[count] = hash;
            count += 1;
        }
    }
    return buffer[0..count];
}

/// MMR Super Peak function
pub fn super_peak(mrange: []const Entry, hasher: anytype) Hash {
    // The maximum number of peaks for n leaves is floor(log2(n)) + 1. For
    // practical MMR sizes (up to millions of entries), this means we rarely
    // need more than 32 peaks. (8.589.934.591)
    std.debug.assert(mrange.len <= 32);

    var buffer: [32]Hash = undefined; // Adjust size based on your needs
    const filtered = filter_nulls(mrange, &buffer);
    return super_peak_inner(filtered, hasher);
}

pub fn super_peak_inner(h: []Hash, hasher: anytype) Hash {
    if (h.len == 0) {
        return [_]u8{0} ** 32;
    }

    if (h.len == 1) {
        return h[0]; // this is always set on len == 1
    }

    var message: [68]u8 = undefined;
    @memcpy(message[0..4], "node");

    var mr = super_peak_inner(h[0..(h.len - 1)], hasher);
    @memcpy(message[4..36], &mr);
    @memcpy(message[36..68], &h[h.len - 1]);

    var H = hasher.init(.{});
    H.update(&message);

    var hash: [32]u8 = undefined;
    H.final(&hash);
    return hash;
}

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

const encoder = @import("codec/encoder.zig");

// TODO: this is covered in the default codec implementation
// as such this can be removed
pub fn encode(mrange: []?Hash, writer: anytype) !void {
    try writer.writeAll(encoder.encodeInteger(mrange.len).as_slice());

    for (mrange) |maybe_hash| {
        if (maybe_hash) |leaf| {
            try writer.writeByte(1);
            try writer.writeAll(&leaf);
        } else {
            try writer.writeByte(0);
        }
    }
}

const testing = std.testing;

test "super_peak calculation" {
    const allocator = std.testing.allocator;
    const Blake2b_256 = std.crypto.hash.blake2.Blake2b(256);

    var mmr = MMR.init(allocator);
    defer mmr.deinit();

    // Test empty MMR
    var peak = super_peak(mmr.items, Blake2b_256);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &peak);

    // Add single leaf
    const leaf1 = [_]u8{1} ** 32;
    try append(&mmr, leaf1, Blake2b_256);
    peak = super_peak(mmr.items, Blake2b_256);
    try testing.expectEqualSlices(u8, &leaf1, &peak);

    // Add second leaf to create a node
    inline for (2..32) |i| {
        const leaf2 = [_]u8{i} ** 32;
        try append(&mmr, leaf2, Blake2b_256);
    }

    peak = super_peak(mmr.items, Blake2b_256);
    std.debug.print("{s}\n", .{std.fmt.fmtSliceHexLower(&peak)});
}

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
