const types = @import("types.zig");

/// Hashes the given data using the provided hasher.
pub fn hashUsingHasher(comptime T: anytype, hasher: type, data: []const []const T) types.Hash {
    var hash_buffer: [32]u8 = undefined;
    var h = hasher.init(.{});
    for (data) |blob| {
        h.update(blob);
    }
    h.update(data);
    h.final(&hash_buffer);

    return hash_buffer;
}
