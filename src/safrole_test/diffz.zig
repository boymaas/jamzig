const std = @import("std");
const diffz = @import("diffz");

const DiffList = std.ArrayListUnmanaged(diffz.Diff);

const dmp = diffz{
    .diff_timeout = 250,
};

pub const Error = error{OutOfMemory} || diffz.DiffError;

pub fn diff_slice(
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
) Error!DiffList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return try dmp.diff(arena.allocator(), before, after, true);
}

test "diff between two strings" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // const arena_allocator = arena.allocator();

    const string1 = "Hello world!";
    const string2 = "Hello brave new world!";

    var diffs = try dmp.diff(
        arena_allocator,
        string1,
        string2,
        true,
    );
    defer diffs.deinit(arena_allocator);

    std.debug.print("diffs: {any}\n", .{diffs.items});
}
