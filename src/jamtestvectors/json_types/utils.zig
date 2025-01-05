const std = @import("std");

pub fn TestVector(comptime T: type) type {
    return struct {
        expected: std.json.Parsed(T),
        allocator: std.mem.Allocator,

        pub fn build_from(
            allocator: std.mem.Allocator,
            json_path: []const u8,
        ) !TestVector(T) {
            const file = try std.fs.cwd().openFile(json_path, .{});
            defer file.close();

            const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
            defer allocator.free(json_buffer);

            var diagnostics = std.json.Diagnostics{};
            var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
            scanner.enableDiagnostics(&diagnostics);
            defer scanner.deinit();

            const expected = std.json.parseFromTokenSource(
                T,
                allocator,
                &scanner,
                .{
                    .ignore_unknown_fields = true,
                    .parse_numbers = false,
                },
            ) catch |err| {
                std.debug.print("Could not parse {s} [{s}]: {}\n{any}", .{ @typeName(T), json_path, err, diagnostics });
                return err;
            };

            return .{
                .expected = expected,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.expected.deinit();
            self.* = undefined;
        }
    };
}

fn compareSlices(context: void, a: []const u8, b: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, a, b);
}

pub const SortedListOfJsonFiles = struct {
    items: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SortedListOfJsonFiles) void {
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn getSortedListOfJsonFilesInDir(allocator: std.mem.Allocator, target_dir: []const u8) !SortedListOfJsonFiles {
    var dir = try std.fs.cwd().openDir(target_dir, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList([]u8).init(allocator);

    var dir_iterator = dir.iterate();
    while (try dir_iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            try entries.append(try allocator.dupe(u8, entry.name));
        }
    }

    std.sort.insertion([]u8, entries.items, {}, compareSlices);

    return .{ .items = try entries.toOwnedSlice(), .allocator = allocator };
}
