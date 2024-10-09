const Blob = []const u8;
const Blobs = []const []const u8;

const Hash = [32]u8;

fn all_blobs_same_size(blobs: Blobs) bool {
    if (blobs.len <= 1) {
        return true;
    }

    const size = blobs[0].len;
    for (blobs) |blob| {
        if (blob.len != size) {
            return false;
        }
    }

    return true;
}

const Result = union(enum(u2)) {
    Hash: Hash,
    Blob: Blob,
    BlobAlloc: Blob,

    pub fn getSlice(self: *const @This()) []const u8 {
        switch (self.*) {
            .Blob => return self.Blob,
            .BlobAlloc => return self.BlobAlloc,
            .Hash => return &self.Hash,
        }
    }

    pub fn len(self: *const @This()) usize {
        switch (self.*) {
            .Blob => return self.Blob.len,
            .BlobAlloc => return self.BlobAlloc.len,
            .Hash => return self.Hash.len,
        }
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .BlobAlloc => allocator.free(self.BlobAlloc),
            else => {},
        }
    }
};

// (296) The underlying function for our Merkle trees is the node function N,
// which accepts some sequence of blobs of somelength n and provides either
// such a blob back or a hash
pub fn N(blobs: Blobs, comptime hasher: type) Result {
    std.debug.assert(all_blobs_same_size(blobs));

    if (blobs.len == 0) {
        return .{ .Hash = [_]u8{0} ** 32 };
    } else if (blobs.len == 1) {
        return .{ .Blob = blobs[0] };
    } else {
        const mid = (blobs.len + 1) / 2; // Round up division
        const prefix = [_]u8{ 'n', 'o', 'd', 'e' };
        const left = N(blobs[0..mid], hasher);
        const right = N(blobs[mid..], hasher);

        var h = hasher.init(.{});
        h.update(&prefix);
        h.update(left.getSlice());
        h.update(right.getSlice());

        var hash_buffer: [32]u8 = undefined;
        h.final(&hash_buffer);

        return .{ .Hash = hash_buffer };
    }
}

// (297)
// We also define the trace function T , which returns each opposite node
// from top to bottom as the tree is navigated toarrive at some leaf
// corresponding to the item of a given index into the sequence. It is
// useful in creating justifications of data inclusion
pub fn T(allocator: std.mem.Allocator, blobs: Blobs, index: usize, comptime hasher: type) Result {
    std.debug.assert(all_blobs_same_size(blobs));

    if (blobs.len == 0 or blobs.len == 1) {
        return Result{ .Blob = &[_]u8{} };
    }
    const a = N(P_s(false, blobs, index), hasher);
    const b = T(allocator, P_s(true, blobs, index), index - P_i(blobs, index), hasher);

    // alocate a blob with the size of a and b
    var blob: []u8 = allocator.alloc(u8, a.getSlice().len + b.getSlice().len) catch unreachable;
    // copy in a and b
    @memcpy(blob[0..a.len()], a.getSlice());
    @memcpy(blob[a.len()..], b.getSlice());

    a.deinit(allocator);
    b.deinit(allocator);

    return .{ .BlobAlloc = blob };
}

pub fn P_i(blobs: Blobs, index: usize) usize {
    const mid = (blobs.len + 1) / 2; // Round up division
    if (index < mid) {
        return 0;
    } else {
        return mid;
    }
}

pub fn P_s(s: bool, blobs: Blobs, index: usize) Blobs {
    const mid = (blobs.len + 1) / 2; // Round up division
    if ((index < mid) == s) {
        return blobs[0..mid];
    } else {
        return blobs[mid..];
    }
}

// This is suitable for creating proofs on data which is not much greater than
// 32 octets in length since it avoids hashingeach item in the sequence. For
// sequences with larger data items, it is better to hash them beforehand to
// ensure proof-sizeis minimal since each proof will generally contain a data
// item
pub fn M_b(blobs: Blobs, comptime hasher: type) Hash {
    std.debug.assert(all_blobs_same_size(blobs));

    if (blobs.len == 1) {
        var hash_buffer: [32]u8 = undefined;
        var h = hasher.init(.{});
        h.update(blobs[0]);
        h.final(&hash_buffer);

        return hash_buffer;
    } else {
        return N(blobs, hasher).Hash;
    }
}

const std = @import("std");
const testing = std.testing;

const testHasher = std.crypto.hash.blake2.Blake2b(256);

test "N function - empty input" {
    const blobs = [_][]const u8{};
    const result = N(&blobs, testHasher);
    try testing.expect(result == .Hash);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &result.Hash);
}

test "N function - single blob" {
    const blobs = [_][]const u8{"hello"};
    const result = N(&blobs, testHasher);
    try testing.expect(result == .Blob);
    try testing.expectEqualSlices(u8, "hello", result.Blob);
}

test "N function - multiple blobs" {
    const blobs = [_][]const u8{ "hello", "world" };
    const result = N(&blobs, testHasher);
    try testing.expect(result == .Hash);
    // The actual hash value will depend on the hashFn implementation
}

test "T function - empty input" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{};
    const result = T(allocator, &blobs, 0, testHasher);
    defer result.deinit(allocator);

    try testing.expect(result == .Blob);
    try testing.expectEqualSlices(u8, &[_]u8{}, result.Blob);
}

test "T function - single blob" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{"hello"};
    const result = T(allocator, &blobs, 0, testHasher);
    defer result.deinit(allocator);

    try testing.expect(result == .Blob);
    try testing.expectEqualSlices(u8, &[_]u8{}, result.Blob);
}

test "T function - multiple blobs" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    const result = T(allocator, &blobs, 2, testHasher);
    defer result.deinit(allocator);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "addcbd7aee4b1baab8fc648daece466d8801fb0ffb8f03ed3f055dd206e7a5ce");
    try testing.expectEqualSlices(u8, expected, result.BlobAlloc);
}

test "M_b function - empty input" {
    const blobs = [_][]const u8{};
    const result = M_b(&blobs, testHasher);

    // The result should be the same as N function for empty input
    const expected = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &expected, &result);
}

test "M_b function - single blob" {
    const blob = [_][]const u8{"hello"};
    const result = M_b(&blob, testHasher);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf");
    try testing.expectEqualSlices(u8, expected, &result);
}

test "M_b function - multiple blobs" {
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    const result = M_b(&blobs, testHasher);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "41505441F20EE9AEE79098A48A868C77F625DF1AFFD4F66A84A58158B8CF026F");
    try testing.expectEqualSlices(u8, expected, &result);
}
