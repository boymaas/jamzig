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

/// Fisher-Yates shuffle implementation following the formal specification
/// This is an optimized implementation that uses O(n) memory instead of O(n²),
/// while preserving the exact same results as the original recursive implementation.
pub fn shuffleWithHash(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []T,
    hash: [32]u8,
) void {
    // Handle empty sequence case
    if (sequence.len < 1) return;

    // Create a temporary array for the result
    var result = allocator.alloc(T, sequence.len) catch |err| {
        std.debug.print("Failed to allocate memory for shuffle result: {}\n", .{err});
        return;
    };
    defer allocator.free(result);
    
    // Create a temporary working copy of the sequence
    var seq_copy = allocator.alloc(T, sequence.len) catch |err| {
        std.debug.print("Failed to allocate memory for shuffle working copy: {}\n", .{err});
        return;
    };
    defer allocator.free(seq_copy);
    
    @memcpy(seq_copy, sequence);
    
    var seq_len = sequence.len;
    
    // Process each element in order (Fisher-Yates algorithm)
    for (0..sequence.len) |i| {
        // Calculate index based on entropy
        const idx = deriveEntropy(i, hash) % seq_len;
        
        // Take the element at that index for the result
        result[i] = seq_copy[idx];
        
        // Replace the selected element with the last element in the working set
        // This effectively removes the selected element from consideration
        if (idx < seq_len - 1) {
            seq_copy[idx] = seq_copy[seq_len - 1];
        }
        
        // Reduce the working set size
        seq_len -= 1;
    }
    
    // Copy result back to the input sequence
    @memcpy(sequence, result);
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
