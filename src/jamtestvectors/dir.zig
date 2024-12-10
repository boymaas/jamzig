const std = @import("std");
const Allocator = std.mem.Allocator;
const OrderedFiles = @import("../tests/ordered_files.zig");
const parser = @import("parser.zig");

const Params = @import("../jam_params.zig").Params;

/// A collection of test vectors with lifecycle management
pub fn TestVectorList(comptime T: type) type {
    return struct {
        const Self = @This();

        vectors: std.ArrayList(T),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .vectors = std.ArrayList(T).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.vectors.items) |*vector| {
                vector.deinit(self.allocator);
            }
            self.vectors.deinit();
        }

        /// Add a single test vector to the list
        pub fn append(self: *Self, vector: T) !void {
            try self.vectors.append(vector);
        }
    };
}

/// Build a list of test vectors from an ordered file list
pub fn scan(
    comptime T: type,
    comptime params: Params,
    allocator: Allocator,
    dir_path: []const u8,
) !TestVectorList(T) {
    // Get ordered list of files
    var ordered_files = try OrderedFiles.getOrderedFiles(allocator, dir_path);
    defer ordered_files.deinit();

    var vectors = TestVectorList(T).init(allocator);
    errdefer vectors.deinit();

    // Process each JSON file in order
    for (ordered_files.items()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bin")) {
            continue;
        }

        const vector = try parser.parseTestVector(T, params, allocator, entry.path);
        try vectors.append(vector);
    }

    return vectors;
}
