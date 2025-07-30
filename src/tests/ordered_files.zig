const std = @import("std");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const OrderedFileList = struct {
    allocator: Allocator,
    files: ArrayList(Entry),

    pub fn items(self: *const @This()) []Entry {
        return self.files.items;
    }

    pub fn deinit(self: *OrderedFileList) void {
        for (self.files.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.files.deinit();
        self.* = undefined;
    }
};

pub const Entry = struct {
    name: []const u8,
    path: []const u8,

    pub fn slurp(self: Entry, allocator: Allocator) !@import("slurp.zig").SlurpedFile {
        return @import("slurp.zig").slurpFile(allocator, self.path);
    }

    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn deepClone(self: Entry, allocator: Allocator) !Entry {
        return Entry{
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
        };
    }
};

pub fn getOrderedFiles(allocator: Allocator, dir_path: []const u8) !OrderedFileList {
    return getOrderedFilesWithFilter(allocator, dir_path, struct {
        fn acceptAll(_: []const u8) bool {
            return true;
        }
    }.acceptAll);
}

pub fn getOrderedFilesWithFilter(
    allocator: Allocator,
    dir_path: []const u8,
    filterFn: fn (name: []const u8) bool,
) !OrderedFileList {
    var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var files = ArrayList(Entry).init(allocator);
    var dir_iterator = dir.iterate();

    // NOTE: memory of path becomes invalid after next next() call
    while (try dir_iterator.next()) |path| {
        if (path.kind == .file and filterFn(path.name)) {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, path.name });
            try files.append(.{
                .name = try allocator.dupe(u8, path.name),
                .path = full_path,
            });
        }
    }

    // Sort files by name
    std.sort.insertion(Entry, files.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return .{
        .allocator = allocator,
        .files = files,
    };
}
