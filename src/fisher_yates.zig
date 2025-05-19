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

/// Core Fisher-Yates implementation used by all public functions
/// Takes result and working copy slices to avoid code duplication
fn shuffleCore(
    comptime T: type,
    sequence: []T,
    result: []T,
    seq_copy: []T,
    hash: [32]u8,
) void {
    // Copy input to working copy
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

/// Fisher-Yates shuffle implementation following the formal specification
pub fn shuffleWithHashAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []T,
    hash: [32]u8,
) void {
    // Handle empty sequence case
    if (sequence.len < 1) return;

    // Allocate a single buffer for both the result and working copy
    const buffer = allocator.alloc(T, sequence.len * 2) catch |err| {
        std.debug.print("Failed to allocate memory for shuffle: {}\n", .{err});
        return;
    };
    defer allocator.free(buffer);

    // Split the buffer into result and working copy sections
    const result = buffer[0..sequence.len];
    const seq_copy = buffer[sequence.len..];

    // Use the common core implementation
    shuffleCore(T, sequence, result, seq_copy, hash);
}

// Constant representing the maximum safe allocation on stack (in bytes)
const MAX_SAFE_STACK_BYTES = 500 * 1024;

/// Compile-time maximum size Fisher-Yates shuffle with zero heap allocations
/// This function is ideal for where the maximum count is known at compile time
pub fn shuffleWithHash(
    comptime T: type,
    comptime max_size: usize,
    sequence: []T,
    hash: [32]u8,
) void {
    // Calculate total bytes needed for both arrays at compile time
    const total_bytes_needed = 2 * max_size * @sizeOf(T);

    // If the size is too large for stack allocation, panic at compile time
    if (comptime total_bytes_needed > MAX_SAFE_STACK_BYTES) {
        @compileError("Fisher-Yates stack arrays would exceed safe stack size limit. " ++
            "Array size: " ++ std.fmt.comptimePrint("{}", .{total_bytes_needed}) ++ " bytes, " ++
            "limit: " ++ std.fmt.comptimePrint("{}", .{MAX_SAFE_STACK_BYTES}) ++ " bytes. " ++
            "Use shuffleWithHashAlloc for large sequences.");
    }

    // Handle empty sequence case
    if (sequence.len < 1) return;

    // Verify the sequence size is within compile-time limits
    if (sequence.len > max_size) {
        @panic("shuffleWithHash: sequence length exceeds compile-time maximum");
    }

    // Fixed-size implementation - uses stack memory instead of heap
    var result: [max_size]T = undefined;
    var seq_copy: [max_size]T = undefined;

    // Only use the portion of the arrays we need
    const result_slice = result[0..sequence.len];
    const seq_copy_slice = seq_copy[0..sequence.len];

    // Use the common core implementation
    shuffleCore(T, sequence, result_slice, seq_copy_slice, hash);
}

/// The original shuffle implementation (for backward compatibility)
pub fn shuffleAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []T,
    entropy: [32]u8,
) void {
    shuffleWithHashAlloc(T, allocator, sequence, entropy);
}

pub fn shuffle(
    comptime T: type,
    comptime max_size: usize,
    sequence: []T,
    entropy: [32]u8,
) void {
    shuffleWithHash(T, max_size, sequence, entropy);
}
