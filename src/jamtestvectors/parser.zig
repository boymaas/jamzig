const std = @import("std");
const codec = @import("../codec.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;

/// Generic test vector parser that loads and parses a single binary test vector file
pub fn parseTestVector(comptime T: type, comptime params: Params, allocator: std.mem.Allocator, file_path: []const u8) !T {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return try codec.deserializeAlloc(T, params, allocator, file.reader());
}
