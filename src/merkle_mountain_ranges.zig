const std = @import("std");
const utils = @import("merkle/utils.zig");
const types = @import("merkle/types.zig");
const encoder = @import("codec/encoder.zig");

const Hash = types.Hash;
const Entry = ?Hash;

/// MMR is defined as a sequence of optional peaks per graypaper E.2
pub const MMR = std.ArrayList(Entry);

/// Filter nulls from the MMR sequence to get the actual peaks
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

/// Implements MR super peak function
pub fn super_peak(mrange: []const Entry, hasher: anytype) Hash {
    // The maximum number of peaks for n leaves is floor(log2(n)) + 1. For
    // practical MMR sizes (up to millions of entries), this means we rarely
    // need more than 32 peaks. (8.589.934.591)
    std.debug.assert(mrange.len <= 32);

    var buffer: [32]Hash = undefined;
    const filtered = filter_nulls(mrange, &buffer);
    return super_peak_inner(filtered, hasher);
}

pub fn super_peak_inner(h: []Hash, hasher: anytype) Hash {
    // Base case: empty sequence returns zero hash
    if (h.len == 0) {
        return [_]u8{0} ** 32;
    }

    // Single peak case returns the peak directly
    if (h.len == 1) {
        return h[0];
    }

    // Recursive case: combine peaks according to specification
    // Recursively process h[0..(h.len-1)] peaks
    var mr = super_peak_inner(h[0..(h.len - 1)], hasher);

    var hash: [32]u8 = undefined;
    var H = hasher.init(.{});
    H.update("peak");
    H.update(&mr);
    H.update(&h[h.len - 1]);
    H.final(&hash);

    return hash;
}

/// Implements A append function from graypaper equation E.8
pub fn append(mrange: *MMR, leaf: Hash, hasher: anytype) !void {
    _ = try P(mrange, leaf, 0, hasher);
}

/// Implements P helper function from graypaper equation E.8
pub fn P(mrange: *MMR, leaf: Hash, n: usize, hasher: anytype) !*MMR {
    if (n >= mrange.items.len) {
        // Base case: extend MMR with new leaf
        try mrange.append(leaf);
        return mrange;
    }

    if (mrange.items[n] == null) {
        // Available slot case: place leaf
        return R(mrange, n, leaf);
    }

    // Combine and recurse case per specification
    var combined: [32]u8 = undefined;
    var H = hasher.init(.{});
    H.update(&mrange.items[n].?);
    H.update(&leaf);
    H.final(&combined);

    return P(
        try R(mrange, n, null),
        combined,
        n + 1,
        hasher,
    );
}

/// Implements R helper function from graypaper
pub fn R(s: *MMR, i: usize, v: Entry) !*MMR {
    if (std.meta.eql(s.items[i], v)) {
        return s;
    }
    s.items[i] = v;
    return s;
}

/// Implements EM encoding function from graypaper equation E.9
pub fn encode(mrange: []?Hash, writer: anytype) !void {
    // First encode the nulls as a sequence of bits
    try writer.writeAll(encoder.encodeInteger(mrange.len).as_slice());

    // Then encode each peak
    for (mrange) |maybe_hash| {
        if (maybe_hash) |hash| {
            try writer.writeByte(1);
            try writer.writeAll(&hash);
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
