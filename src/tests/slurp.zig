const std = @import("std");

// TODO: we have a utils slurp as well unify

pub const SlurpedFile = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,

    pub fn deinit(self: *SlurpedFile) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
};

pub fn slurpFile(allocator: std.mem.Allocator, path: []const u8) !SlurpedFile {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    return SlurpedFile{
        .allocator = allocator,
        .buffer = buffer,
    };
}
