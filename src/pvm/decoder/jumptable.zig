const std = @import("std");

const trace = @import("../../tracing.zig").scoped(.pvm);

pub const JumpTable = struct {
    indices: []u32,

    pub fn init(allocator: std.mem.Allocator, item_length: usize, bytes: []const u8) !JumpTable {
        const span = trace.span(.jump_table_init);
        defer span.deinit();

        // Length of jump table should be a multiple of item length!"
        std.debug.assert(item_length == 0 or bytes.len % item_length == 0);

        const length = if (item_length == 0) 0 else bytes.len / item_length;

        var indices = try allocator.alloc(u32, length);

        var i: usize = 0;
        while (i < bytes.len) : (i += item_length) {
            const idx = i / item_length;
            const value = readPackedU32(bytes[i..][0..item_length]);
            span.debug("index {d}: {d}", .{ idx, value });
            indices[idx] = value;
        }

        return JumpTable{
            .indices = indices,
        };
    }

    pub inline fn getDestination(self: *const JumpTable, index: usize) u32 {
        return self.indices[index % self.indices.len]; // FIXME: error checking
    }

    pub inline fn len(self: *const JumpTable) usize {
        return self.indices.len;
    }

    pub fn deinit(self: *JumpTable, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
        self.* = undefined;
    }
};

test JumpTable {
    const allocator = std.testing.allocator;

    // Test data
    const item_length: usize = 4;
    const test_bytes = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00 };

    // Initialize JumpTable
    var jump_table = try JumpTable.init(allocator, item_length, &test_bytes);
    defer jump_table.deinit(allocator);

    // Test getDestination
    try std.testing.expectEqual(@as(u32, 1), jump_table.getDestination(0));
    try std.testing.expectEqual(@as(u32, 2), jump_table.getDestination(1));
    try std.testing.expectEqual(@as(u32, 3), jump_table.getDestination(2));

    // Test with empty input
    var empty_jump_table = try JumpTable.init(allocator, 0, &[_]u8{});
    defer empty_jump_table.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), empty_jump_table.indices.len);
}

/// Reads an `u32` value from a slice of bytes. The byte slice can be 1 to 4 bytes long.
/// If the slice is shorter than 4 bytes, the value is padded with zeros.
pub fn readPackedU32(bytes: []const u8) u32 {
    // Ensure the input length is within the acceptable range
    if (bytes.len == 0 or bytes.len > 4) {
        @panic("Invalid byte length. Must be between 1 and 4.");
    }

    var value: u32 = 0;

    // Read each byte and shift it to its correct position in the u32 value
    for (bytes, 0..) |byte, index| {
        value |= @as(u32, @intCast(byte)) << @intCast(index * 8);
    }

    return value;
}

test "Read packed u32 from byte slices of different lengths" {
    const assert = std.testing.expect;

    try assert(readPackedU32(&[_]u8{0x01}) == 0x01);
    try assert(readPackedU32(&[_]u8{ 0x01, 0x02 }) == 0x0201);
    try assert(readPackedU32(&[_]u8{ 0x01, 0x02, 0x03 }) == 0x030201);
    try assert(readPackedU32(&[_]u8{ 0x01, 0x02, 0x03, 0x04 }) == 0x04030201);
}
