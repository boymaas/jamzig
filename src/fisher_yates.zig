

const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// E_4 from graypaper
inline fn encodeU32(n: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, n, .little);
    return bytes;
}

/// E_4^(-1) from graypaper
inline fn decodeU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Q function from graypaper F.2: Q(i, h) = E_4^(-1)(H(h ++ E_4(floor(i/8)))[(4i mod 32):(4i mod 32)+4])
pub fn deriveEntropy(i: usize, hash: [32]u8) u32 {
    const idx = i / 8;
    const encoded_idx = encodeU32(@intCast(idx));

    var hasher = Blake2b256.init(.{});
    hasher.update(&hash);
    hasher.update(&encoded_idx);
    var output: [32]u8 = undefined;
    hasher.final(&output);

    const start = (4 * i) % 32;
    return decodeU32(output[start .. start + 4]);
}

/// Preconditions: sequence.len == result.len == seq_copy.len, hash.len == 32
fn shuffleCore(
    comptime T: type,
    sequence: []T,
    result: []T,
    seq_copy: []T,
    hash: [32]u8,
) void {
    @memcpy(seq_copy, sequence);

    var seq_len = sequence.len;

    for (0..sequence.len) |i| {
        const idx = deriveEntropy(i, hash) % seq_len;

        result[i] = seq_copy[idx];

        if (idx < seq_len - 1) {
            seq_copy[idx] = seq_copy[seq_len - 1];
        }

        seq_len -= 1;
    }

    @memcpy(sequence, result);
}

/// Memory: Allocates 2 * sequence.len * @sizeOf(T) bytes
pub fn shuffleWithHashAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    sequence: []T,
    hash: [32]u8,
) !void {
    if (sequence.len == 0) return;

    const buffer = try allocator.alloc(T, sequence.len * 2);
    defer allocator.free(buffer);

    const result = buffer[0..sequence.len];
    const seq_copy = buffer[sequence.len..];

    shuffleCore(T, sequence, result, seq_copy, hash);
}

const MAX_SAFE_STACK_BYTES: usize = 500 * 1024;

/// Uses stack allocation for sequences up to max_size elements. Panics if sequence.len > max_size.
/// Memory: Uses 2 * max_size * @sizeOf(T) bytes of stack space
pub fn shuffleWithHash(
    comptime T: type,
    comptime max_size: usize,
    sequence: []T,
    hash: [32]u8,
) void {
    const total_bytes_needed = 2 * max_size * @sizeOf(T);

    if (comptime total_bytes_needed > MAX_SAFE_STACK_BYTES) {
        @compileError("Fisher-Yates stack arrays would exceed safe stack size limit. " ++
            "Array size: " ++ std.fmt.comptimePrint("{}", .{total_bytes_needed}) ++ " bytes, " ++
            "limit: " ++ std.fmt.comptimePrint("{}", .{MAX_SAFE_STACK_BYTES}) ++ " bytes. " ++
            "Use shuffleWithHashAlloc for large sequences.");
    }

    if (sequence.len == 0) return;

    var result: [max_size]T = undefined;
    var seq_copy: [max_size]T = undefined;

    const result_slice = result[0..sequence.len];
    const seq_copy_slice = seq_copy[0..sequence.len];

    shuffleCore(T, sequence, result_slice, seq_copy_slice, hash);
}

pub const shuffleAlloc = shuffleWithHashAlloc;
pub const shuffle = shuffleWithHash;
