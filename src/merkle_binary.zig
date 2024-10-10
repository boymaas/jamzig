const std = @import("std");
const crypto = @import("crypto");

// Define a constant zero hash used for padding
const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;
const EMPTY_BLOB: []const u8 = &[_]u8{};

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
        return .{ .Hash = ZERO_HASH };
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
        return Result{ .Blob = EMPTY_BLOB };
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

/// This is suitable for creating proofs on data which is not much greater than
/// 32 octets in length since it avoids hashingeach item in the sequence. For
/// sequences with larger data items, it is better to hash them beforehand to
/// ensure proof-sizeis minimal since each proof will generally contain a data
/// item
pub fn M_b(blobs: Blobs, comptime hasher: type) Hash {
    std.debug.assert(all_blobs_same_size(blobs));

    if (blobs.len == 1) {
        return hashUsingHasher(hasher, blobs[0]);
    } else {
        return N(blobs, hasher).Hash;
    }
}

/// Hashes the given data using the provided hasher.
fn hashUsingHasher(hasher: type, data: []const u8) Hash {
    var hash_buffer: [32]u8 = undefined;
    var h = hasher.init(.{});
    h.update(data);
    h.final(&hash_buffer);

    return hash_buffer;
}

const testing = std.testing;

const testHasher = std.crypto.hash.blake2.Blake2b(256);

test "N_empty_input" {
    const blobs = [_][]const u8{};
    const result = N(&blobs, testHasher);
    try testing.expect(result == .Hash);
    try testing.expectEqualSlices(u8, &ZERO_HASH, &result.Hash);
}

test "N_single_blob" {
    const blobs = [_][]const u8{"hello"};
    const result = N(&blobs, testHasher);
    try testing.expect(result == .Blob);
    try testing.expectEqualSlices(u8, "hello", result.Blob);
}

test "N_function_multiple_blobs" {
    const blobs = [_][]const u8{ "hello", "world" };
    const result = N(&blobs, testHasher);
    try testing.expect(result == .Hash);
    // The actual hash value will depend on the hashFn implementation
}

test "T_function_empty_input" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{};
    const result = T(allocator, &blobs, 0, testHasher);
    defer result.deinit(allocator);

    try testing.expect(result == .Blob);
    try testing.expectEqualSlices(u8, EMPTY_BLOB, result.Blob);
}

test "T_function_single_blob" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{"hello"};
    const result = T(allocator, &blobs, 0, testHasher);
    defer result.deinit(allocator);

    try testing.expect(result == .Blob);
    try testing.expectEqualSlices(u8, EMPTY_BLOB, result.Blob);
}

test "T_function_multiple_blobs" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    const result = T(allocator, &blobs, 2, testHasher);
    defer result.deinit(allocator);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "addcbd7aee4b1baab8fc648daece466d8801fb0ffb8f03ed3f055dd206e7a5ce");
    try testing.expectEqualSlices(u8, expected, result.BlobAlloc);
}

test "M_b_function_empty_input" {
    const blobs = [_][]const u8{};
    const result = M_b(&blobs, testHasher);

    // The result should be the same as N function for empty input
    const expected = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &expected, &result);
}

test "M_b_function_single_blob" {
    const blob = [_][]const u8{"hello"};
    const result = M_b(&blob, testHasher);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf");
    try testing.expectEqualSlices(u8, expected, &result);
}

test "M_b_function_multiple_blobs" {
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    const result = M_b(&blobs, testHasher);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "41505441F20EE9AEE79098A48A868C77F625DF1AFFD4F66A84A58158B8CF026F");
    try testing.expectEqualSlices(u8, expected, &result);
}

/// Prefix used for leaf hashes.
const LEAF_PREFIX: [4]u8 = [_]u8{ 'l', 'e', 'a', 'f' };

/// Applies the constancy preprocessor `C` on a given sequence of items `v`.
/// This function hashes all data items with a fixed prefix, and then pads
/// the resulting hashes to the next power of two with a zero hash.
///
/// \param v: Array of data items to preprocess.
/// \return Array of hashed and padded data items of length equal to the next power of two.
fn constancyPreprocessor(allocator: std.mem.Allocator, v: []const Blob, hasher: type) ![]Hash {
    const len = v.len;
    const nextPowerOfTwo = @as(usize, 1) <<
        @as(
        u6,
        @intFromFloat(@ceil(std.math.log2(@as(f32, @floatFromInt(@max(1, len)))))),
    );

    // Allocate the resulting array with the required length
    var v_prime = try allocator.alloc(Hash, nextPowerOfTwo);

    // Hash each item in the input sequence with the leaf prefix
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var h = hasher.init(.{});
        h.update(&LEAF_PREFIX);
        h.update(v[i]);
        h.final(&v_prime[i]);
    }

    // Fill the remaining items in the sequence with the zero hash value
    while (i < nextPowerOfTwo) : (i += 1) {
        v_prime[i] = ZERO_HASH;
    }

    return v_prime;
}

// Example usage of constancyPreprocessor in a Merkle tree function
test "constancyPreprocessor" {
    const allocator = std.testing.allocator;

    const original_data = [_][]const u8{
        "data1",
        "data2",
        "data3",
    };

    // Apply the constancy preprocessor to ensure a consistent input format.
    const processed_data = try constancyPreprocessor(
        allocator,
        &original_data,
        testHasher,
    );
    defer allocator.free(processed_data);

    // Check if the length is 4 (nearest power of two)
    try testing.expectEqual(@as(usize, 4), processed_data.len);

    // Expected hashes for each input, we are prepending leaf
    const expected_hashes = [_][32]u8{
        hashUsingHasher(testHasher, "leafdata1"),
        hashUsingHasher(testHasher, "leafdata2"),
        hashUsingHasher(testHasher, "leafdata3"),
    };

    // Check if the first three hashes are correct
    for (original_data, 0..) |_, i| {
        try testing.expectEqualSlices(u8, &expected_hashes[i], &processed_data[i]);
    }

    // Check if the last hash is the zero hash
    try testing.expectEqualSlices(u8, &ZERO_HASH, &processed_data[3]);
}
