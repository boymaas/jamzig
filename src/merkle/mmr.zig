const std = @import("std");
const types = @import("types.zig");
const encoder = @import("../codec/encoder.zig");

const Hash = types.Hash;
const Entry = ?Hash;

pub const MMR = struct {
    peaks: std.ArrayList(?Hash),

    pub fn init(allocator: std.mem.Allocator) MMR {
        return .{
            .peaks = std.ArrayList(?Hash).init(allocator),
        };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !MMR {
        return .{
            .peaks = try std.ArrayList(?Hash).initCapacity(allocator, capacity),
        };
    }

    /// Takes ownership of slice - caller must NOT free it afterward.
    pub fn fromOwnedSlice(allocator: std.mem.Allocator, owned: []?Hash) MMR {
        return .{
            .peaks = std.ArrayList(?Hash).fromOwnedSlice(allocator, owned),
        };
    }

    pub fn items(self: *const MMR) []const ?Hash {
        return self.peaks.items;
    }

    /// Transfers ownership to caller - MMR is invalid after this.
    pub fn toOwnedSlice(self: *MMR) ![]?Hash {
        return try self.peaks.toOwnedSlice();
    }

    pub fn deinit(self: *MMR) void {
        self.peaks.deinit();
        self.* = undefined;
    }
};

pub fn filterNulls(mrange: []const Entry, buffer: []Hash) []Hash {
    var count: usize = 0;
    for (mrange) |maybe_hash| {
        if (maybe_hash) |hash| {
            buffer[count] = hash;
            count += 1;
        }
    }
    return buffer[0..count];
}

pub fn superPeak(mrange: []const Entry, hasher: anytype) Hash {
    // 32 peaks supports 8+ billion leaves
    std.debug.assert(mrange.len <= 32);

    var buffer: [32]Hash = undefined;
    const filtered = filterNulls(mrange, &buffer);
    return superPeakInner(filtered, hasher);
}

fn superPeakInner(h: []Hash, hasher: anytype) Hash {
    if (h.len == 0) {
        return [_]u8{0} ** 32;
    }

    if (h.len == 1) {
        return h[0];
    }

    var mr = superPeakInner(h[0..(h.len - 1)], hasher);

    var hash: [32]u8 = undefined;
    var H = hasher.init(.{});
    H.update("peak");
    H.update(&mr);
    H.update(&h[h.len - 1]);
    H.final(&hash);

    return hash;
}

pub fn append(mrange: *MMR, leaf: Hash, hasher: anytype) !void {
    _ = try P(mrange, leaf, 0, hasher);
}

fn P(mrange: *MMR, leaf: Hash, n: usize, hasher: anytype) !*MMR {
    if (n >= mrange.peaks.items.len) {
        try mrange.peaks.append(leaf);
        return mrange;
    }

    if (mrange.peaks.items[n] == null) {
        return R(mrange, n, leaf);
    }

    var combined: [32]u8 = undefined;
    var H = hasher.init(.{});
    H.update(&mrange.peaks.items[n].?);
    H.update(&leaf);
    H.final(&combined);

    return P(
        R(mrange, n, null),
        combined,
        n + 1,
        hasher,
    );
}

fn R(s: *MMR, i: usize, v: Entry) *MMR {
    if (std.meta.eql(s.peaks.items[i], v)) {
        return s;
    }
    s.peaks.items[i] = v;
    return s;
}

pub fn encodePeaks(mrange: []const ?Hash, writer: anytype) !void {
    try writer.writeAll(encoder.encodeInteger(mrange.len).as_slice());

    for (mrange) |maybe_hash| {
        if (maybe_hash) |hash| {
            try writer.writeByte(1);
            try writer.writeAll(&hash);
        } else {
            try writer.writeByte(0);
        }
    }
}

// Alias for backward compatibility
pub const encode = encodePeaks;

const testing = std.testing;

test "superPeak calculation" {
    const allocator = std.testing.allocator;
    const Blake2b_256 = std.crypto.hash.blake2.Blake2b(256);

    var mmr = MMR.init(allocator);
    defer mmr.deinit();

    // Test empty MMR
    var peak = superPeak(mmr.items(), Blake2b_256);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &peak);

    // Add single leaf
    const leaf1 = [_]u8{1} ** 32;
    try append(&mmr, leaf1, Blake2b_256);
    peak = superPeak(mmr.items(), Blake2b_256);
    try testing.expectEqualSlices(u8, &leaf1, &peak);

    // Add more leaves
    inline for (2..32) |i| {
        const leaf2 = [_]u8{i} ** 32;
        try append(&mmr, leaf2, Blake2b_256);
    }

    peak = superPeak(mmr.items(), Blake2b_256);
    std.debug.print("{s}\n", .{std.fmt.fmtSliceHexLower(&peak)});
}

test "mmr append" {
    const allocator = std.testing.allocator;
    var mmr = MMR.init(allocator);
    defer mmr.deinit();

    const leaf1 = [_]u8{1} ** 32;
    const leaf2 = [_]u8{2} ** 32;
    const leaf3 = [_]u8{3} ** 32;

    const Blake2b_256 = std.crypto.hash.blake2.Blake2b(256);

    try append(&mmr, leaf1, Blake2b_256);
    try testing.expectEqual(@as(usize, 1), mmr.peaks.items.len);
    try testing.expectEqualSlices(u8, &leaf1, &mmr.peaks.items[0].?);

    try append(&mmr, leaf2, Blake2b_256);
    try testing.expectEqual(@as(usize, 2), mmr.peaks.items.len);
    try testing.expect(mmr.peaks.items[0] == null);

    try append(&mmr, leaf3, Blake2b_256);
    try testing.expectEqual(@as(usize, 2), mmr.peaks.items.len);
    try testing.expectEqualSlices(u8, &leaf3, &mmr.peaks.items[0].?);
}
