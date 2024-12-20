const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// E_4 encodes a u32 into 4 bytes in little-endian format
inline fn encodeU32(n: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, n, .little);
    return bytes;
}

/// E_4^(-1) decodes 4 bytes in little-endian format to a u32
inline fn decodeU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Q function that derives a sequence of numbers from a hash as per specification F.2
pub fn deriveEntropy(i: usize, hash: [32]u8) u32 {
    // Calculate floor(i/8) and encode it
    const idx = i / 8;
    const encoded_idx = encodeU32(@intCast(idx));

    // Hash the concatenated input
    var hasher = Blake2b256.init(.{});
    hasher.update(&hash);
    hasher.update(&encoded_idx);
    var output: [32]u8 = undefined;
    hasher.final(&output);

    // Take 4 bytes starting at (4i mod 32) and decode
    const start = (4 * i) % 32;
    return decodeU32(output[start .. start + 4]);
}

/// Recursive Fisher-Yates shuffle implementation
fn shuffleRecursive(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []const T,
    entropy_index: usize,
    hash: [32]u8,
) ![]T {
    // Base case: empty sequence returns empty array
    if (sequence.len == 0) {
        return allocator.alloc(T, 0);
    }

    // Calculate index using current entropy value
    const index = deriveEntropy(entropy_index, hash) % sequence.len;

    // Extract head element at calculated index
    const head = sequence[index];

    // Create new sequence with last element moved to index position
    var seq_post = try allocator.alloc(T, sequence.len);
    defer allocator.free(seq_post);

    // Copy original sequence
    @memcpy(seq_post, sequence);

    // Move last element to selected index position
    seq_post[index] = sequence[sequence.len - 1];

    // Recursively shuffle remainder of sequence
    const result = try shuffleRecursive(
        T,
        allocator,
        seq_post[0 .. sequence.len - 1],
        entropy_index + 1,
        hash,
    );

    // Prepend head to recursive result
    var final_result = try allocator.alloc(T, sequence.len);
    final_result[0] = head;
    @memcpy(final_result[1..], result);

    // Free intermediate result
    allocator.free(result);

    return final_result;
}

/// Fisher-Yates shuffle implementation following the formal specification
pub fn shuffleWithHash(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []T,
    hash: [32]u8,
) void {
    // Handle empty sequence case
    if (sequence.len < 1) return;

    // Calculate total memory needed:
    // For each recursion level (sequence.len times):
    // - One temporary sequence of size n-i
    // - One final result array of size n-i
    // where i goes from 0 to sequence.len-1

    // Calculate total memory needed for all recursion levels:
    //
    // For a sequence of n=1023 validators, each validator being 4 bytes (u32):
    // Level 0: two arrays of size 1023 = 2 * 1023 * 4 = 8,184 bytes
    // Level 1: two arrays of size 1022 = 2 * 1022 * 4 = 8,176 bytes
    // Level 2: two arrays of size 1021 = 2 * 1021 * 4 = 8,168 bytes
    // ...and so on until...
    // Level 1022: two arrays of size 1 = 2 * 1 * 4 = 8 bytes
    //
    // Total bytes = sequence.len * (sizeOf(T) * sequence.len)
    // For n=1023, T=u32: 1023 * (4 * 1023) = 4,186,116 bytes ≈ 4.1MB
    //
    // Note: This is an upper bound as we allocate full sequence.len for simplicity,
    // actual memory use is less since each level needs smaller arrays
    //
    // TODO: OPTIMIZE THIS!
    const total_size = sequence.len * (@sizeOf(T) * sequence.len);
    _ = total_size;

    // Initialize arena with calculated capacity
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Perform recursive shuffle and copy result back to input sequence
    if (shuffleRecursive(T, arena.allocator(), sequence, 0, hash)) |result| {
        @memcpy(sequence, result);
    } else |err| {
        std.debug.print("Shuffle failed with error: {}\n", .{err});
        return;
    }
}

/// The original shuffle implementation
pub fn shuffle(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []T,
    entropy: [32]u8,
) void {
    shuffleWithHash(T, allocator, sequence, entropy);
}
