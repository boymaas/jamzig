const std = @import("std");
const utils = @import("utils.zig");
const types = @import("types.zig");
const encoder = @import("../codec/encoder.zig");

const Hash = types.Hash;
const Entry = ?Hash;

/// MMR using ArrayList for internal peak management.
/// This provides automatic growth while maintaining clear ownership semantics.
pub const MMR = struct {
    /// Internal storage for peaks. MMR owns this memory.
    peaks: std.ArrayList(?Hash),
    
    /// Initialize a new empty MMR
    pub fn init(allocator: std.mem.Allocator) MMR {
        return .{
            .peaks = std.ArrayList(?Hash).init(allocator),
        };
    }
    
    /// Initialize MMR with a specific capacity
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !MMR {
        return .{
            .peaks = try std.ArrayList(?Hash).initCapacity(allocator, capacity),
        };
    }
    
    /// Create MMR from an owned slice.
    /// IMPORTANT: This function takes ownership of the slice. The slice must have
    /// been allocated with the same allocator that will be used for future operations.
    /// After calling this function, the caller must NOT free the slice - it will be
    /// freed by MMR.deinit().
    pub fn fromOwnedSlice(allocator: std.mem.Allocator, owned: []?Hash) MMR {
        return .{
            .peaks = std.ArrayList(?Hash).fromOwnedSlice(allocator, owned),
        };
    }
    
    /// Get the peaks as a slice
    pub fn items(self: *const MMR) []const ?Hash {
        return self.peaks.items;
    }
    
    /// Transfer ownership of the peaks array to the caller.
    /// After calling this function, the MMR is no longer valid and
    /// the caller is responsible for freeing the returned slice.
    pub fn toOwnedSlice(self: *MMR) ![]?Hash {
        return try self.peaks.toOwnedSlice();
    }
    
    /// Clean up MMR resources
    pub fn deinit(self: *MMR) void {
        self.peaks.deinit();
        self.* = undefined;
    }
};

/// Filter nulls from the MMR sequence to get the actual peaks
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

/// Computes the super peak (root) of the MMR
pub fn superPeak(mrange: []const Entry, hasher: anytype) Hash {
    // The maximum number of peaks for n leaves is floor(log2(n)) + 1. For
    // practical MMR sizes (up to millions of entries), this means we rarely
    // need more than 32 peaks. (8.589.934.591)
    std.debug.assert(mrange.len <= 32);

    var buffer: [32]Hash = undefined;
    const filtered = filterNulls(mrange, &buffer);
    return superPeakInner(filtered, hasher);
}

fn superPeakInner(h: []Hash, hasher: anytype) Hash {
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
    var mr = superPeakInner(h[0..(h.len - 1)], hasher);

    var hash: [32]u8 = undefined;
    var H = hasher.init(.{});
    H.update("peak");
    H.update(&mr);
    H.update(&h[h.len - 1]);
    H.final(&hash);

    return hash;
}

/// Appends a leaf to the MMR. May allocate if internal storage needs to grow.
pub fn append(mrange: *MMR, leaf: Hash, hasher: anytype) !void {
    _ = try P(mrange, leaf, 0, hasher);
}

/// Helper function for MMR append operation
fn P(mrange: *MMR, leaf: Hash, n: usize, hasher: anytype) !*MMR {
    if (n >= mrange.peaks.items.len) {
        // Base case: extend MMR with new leaf
        try mrange.peaks.append(leaf);
        return mrange;
    }

    if (mrange.peaks.items[n] == null) {
        // Available slot case: place leaf
        return R(mrange, n, leaf);
    }

    // Combine and recurse case per specification
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

/// Updates MMR peak at index i
fn R(s: *MMR, i: usize, v: Entry) *MMR {
    if (std.meta.eql(s.peaks.items[i], v)) {
        return s;
    }
    s.peaks.items[i] = v;
    return s;
}

/// Encodes MMR peaks to writer
pub fn encodePeaks(mrange: []const ?Hash, writer: anytype) !void {
    // First encode the length
    try writer.writeAll(encoder.encodeInteger(mrange.len).as_slice());

    // Then encode each peak with presence bit
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
