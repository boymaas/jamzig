const std = @import("std");
const crypto = @import("crypto");

// Define a constant zero hash used for padding
const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;
const EMPTY_BLOB: []const u8 = &[_]u8{};

/// Prefix used for leaf hashes.
const LEAF_PREFIX: [4]u8 = [_]u8{ 'l', 'e', 'a', 'f' };
/// Prefix used for Node hashes.
const NODE_PREFIX = [_]u8{ 'n', 'o', 'd', 'e' };

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
        const left = N(blobs[0..mid], hasher);
        const right = N(blobs[mid..], hasher);

        var h = hasher.init(.{});
        h.update(&NODE_PREFIX);
        h.update(left.getSlice());
        h.update(right.getSlice());

        var hash_buffer: [32]u8 = undefined;
        h.final(&hash_buffer);

        return .{ .Hash = hash_buffer };
    }
}

/// Specialized function as N, only for hashes
pub fn N_hash(hashes: []const Hash, comptime hasher: type) Hash {
    if (hashes.len == 0) {
        return ZERO_HASH;
    } else if (hashes.len == 1) {
        return hashes[0];
    } else {
        const mid = (hashes.len + 1) / 2; // Round up division
        const left = N_hash(hashes[0..mid], hasher);
        const right = N_hash(hashes[mid..], hasher);

        var h = hasher.init(.{});
        h.update(&NODE_PREFIX);
        h.update(&left);
        h.update(&right);

        var hash_buffer: [32]u8 = undefined;
        h.final(&hash_buffer);

        return hash_buffer;
    }
}

const TraceResult = struct {
    results: []Result,

    pub fn empty() TraceResult {
        return .{ .results = &[_]Result{} };
    }
    pub fn len(self: *const TraceResult) usize {
        return self.results.len;
    }

    pub fn deinit(self: *const TraceResult, allocator: std.mem.Allocator) void {
        for (self.results) |result| {
            result.deinit(allocator);
        }
        allocator.free(self.results);
    }
};

// (297)
// We also define the trace function T , which returns each opposite node
// from top to bottom as the tree is navigated toarrive at some leaf
// corresponding to the item of a given index into the sequence. It is
// useful in creating justifications of data inclusion
pub fn T(
    allocator: std.mem.Allocator,
    blobs: Blobs,
    index: usize,
    comptime hasher: type,
) !TraceResult {
    std.debug.assert(all_blobs_same_size(blobs));

    if (blobs.len == 0 or blobs.len == 1) {
        return TraceResult.empty();
    }
    const a = N(P_s(false, blobs, index), hasher);
    const b = try T(allocator, P_s(true, blobs, index), index - P_i(blobs, index), hasher);
    defer b.deinit(allocator);

    // Allocate a new slice with results which can hold both a and b
    // TODO: optimize this
    var results = try allocator.alloc(Result, b.len() + 1);
    results[0] = a;
    @memcpy(results[1..], b.results);

    return .{ .results = results };
}

pub fn T_hash(
    allocator: std.mem.Allocator,
    hashes: []const Hash,
    index: usize,
    comptime hasher: type,
) ![]Hash {
    if (hashes.len == 0 or hashes.len == 1) {
        return &[_]Hash{};
    }
    const a = N_hash(P_s_hash(false, hashes, index), hasher);
    const b = try T_hash(allocator, P_s_hash(true, hashes, index), index - P_i_hash(hashes, index), hasher);
    defer allocator.free(b);

    var results = try allocator.alloc(Hash, b.len + 1);
    results[0] = a;
    @memcpy(results[1..], b);

    return results;
}

fn P_i_hash(hashes: []const Hash, index: usize) usize {
    const mid = (hashes.len + 1) / 2; // Round up division
    if (index < mid) {
        return 0;
    } else {
        return mid;
    }
}

fn P_s_hash(s: bool, hashes: []const Hash, index: usize) []const Hash {
    const mid = (hashes.len + 1) / 2; // Round up division
    if ((index < mid) == s) {
        return hashes[0..mid];
    } else {
        return hashes[mid..];
    }
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
    const result = try T(allocator, &blobs, 0, testHasher);
    defer result.deinit(allocator);

    try testing.expectEqualSlices(Result, result.results, &[_]Result{});
}

test "T_function_single_blob" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{"hello"};
    const result = try T(allocator, &blobs, 0, testHasher);
    defer result.deinit(allocator);

    try testing.expect(result.results.len == 0);
}

test "T_function_multiple_blobs" {
    const allocator = std.testing.allocator;
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    const result = try T(allocator, &blobs, 2, testHasher);
    defer result.deinit(allocator);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "addcbd7aee4b1baab8fc648daece466d8801fb0ffb8f03ed3f055dd206e7a5ce");
    try testing.expectEqualSlices(u8, expected, &result.results[0].Hash);
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

/// Applies the constancy preprocessor `C` on a given sequence of items `v`.
/// This function hashes all data items with a fixed prefix, and then pads
/// the resulting hashes to the next power of two with a zero hash.
///
/// \param v: Array of data items to preprocess.
/// \return Array of hashed and padded data items of length equal to the next power of two.
fn constancyPreprocessor(allocator: std.mem.Allocator, v: []const Blob, hasher: type) ![]Hash {
    const len = v.len;
    const nextPowerOfTwo =
        try std.math.ceilPowerOfTwo(usize, @max(1, len));

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

/// Computes the Merkle root of a constant-depth binary Merkle tree.
///
/// This function applies the constancy preprocessor to the input data
/// and then computes the root hash of the resulting tree.
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   v: Slice of data items to be included in the Merkle tree
///   H: Hash function to be used (must output 32 bytes)
///
/// Returns:
///   The 32-byte Merkle root hash
///
/// Error: Returns any allocation errors that may occur
pub fn M(allocator: std.mem.Allocator, v: []const Blob, H: type) !Hash {
    const preprocessed = try constancyPreprocessor(allocator, v, H);
    defer allocator.free(preprocessed);
    return N_hash(preprocessed, H);
}

/// Generates a Merkle proof (justification) for a specific item in the tree.
///
/// This function creates a proof that can be used to verify the inclusion
/// of the item at index 'i' in the Merkle tree without having the entire tree.
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   v: Slice of data items in the Merkle tree
///   i: Index of the item for which to generate the proof
///   H: Hash function to be used (must output 32 bytes)
///
/// Returns:
///   A slice of 32-byte hashes forming the Merkle proof
///
/// Error: Returns any allocation errors that may occur
///
pub fn J(allocator: std.mem.Allocator, v: []const Blob, i: usize, H: type) ![]Hash {
    const preprocessed = try constancyPreprocessor(allocator, v, H);
    defer allocator.free(preprocessed);
    return try T_hash(allocator, preprocessed, i, H);
}

/// Generates a partial Merkle proof for a well-aligned subtree.
///
/// This function is similar to J, but it limits the proof to only those
/// nodes required to justify inclusion of a well-aligned subtree of
/// (maximum) size 2^x. This can reduce the size of the proof when the
/// verifier already knows part of the tree.
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   v: Slice of data items in the Merkle tree
///   i: Index of the item for which to generate the proof
///   x: Limits the proof to a subtree of maximum size 2^x
///   H: Hash function to be used (must output 32 bytes)
///
/// Returns:
///   A slice of 32-byte hashes forming the partial Merkle proof
///
/// Error: Returns any allocation errors that may occur
pub fn J_x(allocator: std.mem.Allocator, v: []const Blob, i: usize, x: usize, H: type) ![]Hash {
    var proof = try J(allocator, v, i, H);
    const max_depth: usize = @intFromFloat(@max(
        0.0,
        std.math.ceil(
            // log2(max(1,|v|)) - x
            std.math.log2(@max(1.0, @as(f32, @floatFromInt(v.len)))) - @as(f32, @floatFromInt(x)),
        ),
    ));

    // Truncate prrof if it exceeds the maximum depth
    if (proof.len > max_depth) {
        const truncated = try allocator.alloc(Hash, @intCast(max_depth));
        @memcpy(truncated, proof[0..max_depth]);
        allocator.free(proof);
        return truncated;
    }

    return proof;
}

// Tests
test "M_function" {
    const allocator = std.testing.allocator;
    const data = [_][]const u8{ "data1", "data2", "data3", "data4" };

    const root = try M(allocator, &data, testHasher);

    // The actual hash value will depend on the testHasher implementation
    // Here we're just checking that we get a result of the correct length
    try testing.expectEqual(@as(usize, 32), root.len);
}

test "J_function" {
    const allocator = std.testing.allocator;
    const data = [_][]const u8{ "data1", "data2", "data3", "data4" };

    const proof = try J(allocator, &data, 2, testHasher);
    defer allocator.free(proof);

    // The proof should contain log2(n) hashes, where n is the next power of 2 >= data.len
    try testing.expectEqual(@as(usize, 2), proof.len);

    // Each hash in the proof should be 32 bytes long
    for (proof) |hash| {
        try testing.expectEqual(@as(usize, 32), hash.len);
    }
}

test "J_x_function" {
    const allocator = std.testing.allocator;
    const data = [_][]const u8{
        "data1",
        "data2",
        "data3",
        "data4",
        "data5",
        "data6",
        "data7",
        "data8",
    };

    // Generate a proof for index 3 with x = 1 (subtree of size 2^1 = 2)
    const proof = try J_x(allocator, &data, 3, 1, testHasher);
    defer allocator.free(proof);

    // The proof should be shorter than a full proof
    try testing.expectEqual(@as(usize, 2), proof.len);

    // Each hash in the proof should be 32 bytes long
    for (proof) |hash| {
        try testing.expectEqual(@as(usize, 32), hash.len);
    }
}
