const std = @import("std");
const crypto = @import("../crypto");

const ZERO_HASH: [32]u8 = [_]u8{0} ** 32;
const EMPTY_BLOB: []const u8 = &[_]u8{};

const LEAF_PREFIX: [4]u8 = [_]u8{ 'l', 'e', 'a', 'f' };
const NODE_PREFIX = [_]u8{ 'n', 'o', 'd', 'e' };

const types = @import("types.zig");

const Blob = types.Blob;
const Blobs = types.Blobs;
const Hash = types.Hash;

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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .BlobAlloc => allocator.free(self.BlobAlloc),
            else => {},
        }
        self.* = undefined;
    }
};

// Graypaper (296): node function N
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

pub const TraceView = struct {
    results: []Result,
    
    pub fn len(self: *const TraceView) usize {
        return self.results.len;
    }
};

/// Caller must provide buffer of size ceil(log2(blobs.len)).
pub fn computeTrace(
    blobs: Blobs,
    index: usize,
    trace_buffer: []Result,
    comptime hasher: type,
) []Result {
    std.debug.assert(all_blobs_same_size(blobs));
    
    if (blobs.len == 0 or blobs.len == 1) {
        return trace_buffer[0..0];
    }
    
    var depth: usize = 0;
    var current_blobs = blobs;
    var current_index = index;
    
    while (current_blobs.len > 1) {
        const a = N(P_s(false, current_blobs, current_index), hasher);
        trace_buffer[depth] = a;
        depth += 1;
        
        // Move to next level
        current_blobs = P_s(true, current_blobs, current_index);
        const next_blobs = P_s(true, current_blobs, current_index);
        current_index = current_index - P_i(current_blobs, current_index);
        current_blobs = next_blobs;
    }
    
    return trace_buffer[0..depth];
}

/// Deprecated: use computeTrace with caller-provided buffer
pub fn T(
    allocator: std.mem.Allocator,
    blobs: Blobs,
    index: usize,
    comptime hasher: type,
) !TraceView {
    const max_depth = std.math.log2_int_ceil(usize, @max(1, blobs.len));
    const buffer = try allocator.alloc(Result, max_depth);
    const trace = computeTrace(blobs, index, buffer, hasher);
    return TraceView{ .results = trace };
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

/// Caller must provide buffer of size ceil(log2(hashes.len)).
pub fn computeTraceHashes(
    hashes: []const Hash,
    index: usize,
    trace_buffer: []Hash,
    comptime hasher: type,
) []Hash {
    if (hashes.len == 0 or hashes.len == 1) {
        return trace_buffer[0..0];
    }
    
    var depth: usize = 0;
    var current_hashes = hashes;
    var current_index = index;
    
    while (current_hashes.len > 1) {
        const a = N_hash(P_s_hash(false, current_hashes, current_index), hasher);
        trace_buffer[depth] = a;
        depth += 1;
        
        const next_hashes = P_s_hash(true, current_hashes, current_index);
        current_index = current_index - P_i_hash(current_hashes, current_index);
        current_hashes = next_hashes;
    }
    
    return trace_buffer[0..depth];
}

/// Deprecated: use computeTraceHashes with caller-provided buffer
pub fn T_hash(
    allocator: std.mem.Allocator,
    hashes: []const Hash,
    index: usize,
    comptime hasher: type,
) ![]Hash {
    const max_depth = std.math.log2_int_ceil(usize, @max(1, hashes.len));
    const buffer = try allocator.alloc(Hash, max_depth);
    const trace = computeTraceHashes(hashes, index, buffer, hasher);
    return buffer[0..trace.len];
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

pub fn binaryMerkleRoot(blobs: Blobs, comptime hasher: type) Hash {
    std.debug.assert(all_blobs_same_size(blobs));

    if (blobs.len == 1) {
        return hashUsingHasher(hasher, blobs[0]);
    } else {
        return N(blobs, hasher).Hash;
    }
}

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
}

test "computeTrace empty input" {
    const blobs = [_][]const u8{};
    var trace_buffer: [10]Result = undefined;
    const result = computeTrace(&blobs, 0, &trace_buffer, testHasher);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "computeTrace single blob" {
    const blobs = [_][]const u8{"hello"};
    var trace_buffer: [10]Result = undefined;
    const result = computeTrace(&blobs, 0, &trace_buffer, testHasher);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "computeTrace multiple blobs" {
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    var trace_buffer: [10]Result = undefined;
    const result = computeTrace(&blobs, 2, &trace_buffer, testHasher);
    
    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "addcbd7aee4b1baab8fc648daece466d8801fb0ffb8f03ed3f055dd206e7a5ce");
    try testing.expectEqualSlices(u8, expected, &result[0].Hash);
}

test "binaryMerkleRoot empty input" {
    const blobs = [_][]const u8{};
    const result = binaryMerkleRoot(&blobs, testHasher);
    const expected = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &expected, &result);
}

test "binaryMerkleRoot single blob" {
    const blob = [_][]const u8{"hello"};
    const result = binaryMerkleRoot(&blob, testHasher);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf");
    try testing.expectEqualSlices(u8, expected, &result);
}

test "binaryMerkleRoot multiple blobs" {
    const blobs = [_][]const u8{ "hello", "world", "zig  " };
    const result = binaryMerkleRoot(&blobs, testHasher);

    var buffer: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, "41505441F20EE9AEE79098A48A868C77F625DF1AFFD4F66A84A58158B8CF026F");
    try testing.expectEqualSlices(u8, expected, &result);
}

/// Caller must provide buffer of size nextPowerOfTwo(v.len).
pub fn preprocessConstantDepth(
    v: []const Blob,
    output_buffer: []Hash,
    hasher: type,
) []Hash {
    const len = v.len;
    const next_power = std.math.ceilPowerOfTwoAssert(usize, @max(1, len));
    std.debug.assert(output_buffer.len >= next_power);
    
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var h = hasher.init(.{});
        h.update(&LEAF_PREFIX);
        h.update(v[i]);
        h.final(&output_buffer[i]);
    }

    while (i < next_power) : (i += 1) {
        output_buffer[i] = ZERO_HASH;
    }
    
    return output_buffer[0..next_power];
}

test "preprocessConstantDepth" {
    const original_data = [_][]const u8{
        "data1",
        "data2",
        "data3",
    };

    var workspace: [4]Hash = undefined;
    const processed = preprocessConstantDepth(&original_data, &workspace, testHasher);

    try testing.expectEqual(@as(usize, 4), processed.len);

    const expected_hashes = [_][32]u8{
        hashUsingHasher(testHasher, "leafdata1"),
        hashUsingHasher(testHasher, "leafdata2"),
        hashUsingHasher(testHasher, "leafdata3"),
    };
    
    for (original_data, 0..) |_, i| {
        try testing.expectEqualSlices(u8, &expected_hashes[i], &processed[i]);
    }

    try testing.expectEqualSlices(u8, &ZERO_HASH, &processed[3]);
}

/// Caller must provide workspace of size nextPowerOfTwo(v.len).
pub fn constantDepthMerkleRoot(
    v: []const Blob,
    workspace: []Hash,
    H: type,
) Hash {
    const preprocessed = preprocessConstantDepth(v, workspace, H);
    return N_hash(preprocessed, H);
}

/// Deprecated: use constantDepthMerkleRoot with caller-provided workspace
pub fn M(allocator: std.mem.Allocator, v: []const Blob, H: type) !Hash {
    const size = std.math.ceilPowerOfTwoAssert(usize, @max(1, v.len));
    const workspace = try allocator.alloc(Hash, size);
    defer allocator.free(workspace);
    return constantDepthMerkleRoot(v, workspace, H);
}

/// Caller provides workspace (nextPowerOfTwo size) and trace_buffer.
pub fn generateProof(
    v: []const Blob,
    i: usize,
    workspace: []Hash,
    trace_buffer: []Hash,
    H: type,
) []Hash {
    const preprocessed = preprocessConstantDepth(v, workspace, H);
    return computeTraceHashes(preprocessed, i, trace_buffer, H);
}

/// Deprecated: use generateProof with caller-provided buffers
pub fn J(allocator: std.mem.Allocator, v: []const Blob, i: usize, H: type) ![]Hash {
    const size = std.math.ceilPowerOfTwoAssert(usize, @max(1, v.len));
    const workspace = try allocator.alloc(Hash, size);
    defer allocator.free(workspace);
    
    const preprocessed = preprocessConstantDepth(v, workspace, H);
    return try T_hash(allocator, preprocessed, i, H);
}

/// Partial proof limited to subtree of size 2^x.
pub fn J_x(allocator: std.mem.Allocator, v: []const Blob, i: usize, x: usize, H: type) ![]Hash {
    var proof = try J(allocator, v, i, H);
    const max_depth: usize = @intFromFloat(@max(
        0.0,
        std.math.ceil(
            // log2(max(1,|v|)) - x
            std.math.log2(@max(1.0, @as(f32, @floatFromInt(v.len)))) - @as(f32, @floatFromInt(x)),
        ),
    ));

    if (proof.len > max_depth) {
        const truncated = try allocator.alloc(Hash, @intCast(max_depth));
        @memcpy(truncated, proof[0..max_depth]);
        allocator.free(proof);
        return truncated;
    }

    return proof;
}

test "constantDepthMerkleRoot" {
    const data = [_][]const u8{ "data1", "data2", "data3", "data4" };
    var workspace: [4]Hash = undefined;

    const root = constantDepthMerkleRoot(&data, &workspace, testHasher);

    try testing.expectEqual(@as(usize, 32), root.len);
}

test "generateProof" {
    const data = [_][]const u8{ "data1", "data2", "data3", "data4" };
    var workspace: [4]Hash = undefined;
    var trace_buffer: [10]Hash = undefined;

    const proof = generateProof(&data, 2, &workspace, &trace_buffer, testHasher);

    try testing.expectEqual(@as(usize, 2), proof.len);

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

    const proof = try J_x(allocator, &data, 3, 1, testHasher);
    defer allocator.free(proof);

    try testing.expectEqual(@as(usize, 2), proof.len);

    for (proof) |hash| {
        try testing.expectEqual(@as(usize, 32), hash.len);
    }
}
