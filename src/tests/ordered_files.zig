const std = @import("std");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const OrderedFileList = struct {
    allocator: Allocator,
    files: ArrayList([]const u8),

    pub fn items(self: *@This()) [][]const u8 {
        return self.files.items;
    }

    pub fn deinit(self: *OrderedFileList) void {
        for (self.files.items) |name| {
            self.allocator.free(name);
        }
        self.files.deinit();
    }
};

pub fn getOrderedFiles(allocator: Allocator, dir_path: []const u8) !OrderedFileList {
    var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var files = ArrayList([]const u8).init(allocator);
    var dir_iterator = dir.iterate();

    while (try dir_iterator.next()) |entry| {
        if (entry.kind == .file) {
            const name = try allocator.dupe(u8, entry.name);
            try files.append(name);
        }
    }

    // Sort files by name
    std.sort.insertion([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return .{
        .allocator = allocator,
        .files = files,
    };
}
