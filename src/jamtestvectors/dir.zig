const std = @import("std");
const Allocator = std.mem.Allocator;
const OrderedFiles = @import("../tests/ordered_files.zig");
const loader = @import("loader.zig");

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

        pub fn test_cases(self: *Self) []const T {
            return self.vectors.items;
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(T, "deinit")) {
                const info = @typeInfo(@TypeOf(T.deinit));
                if (info == .@"fn" and info.@"fn".params.len > 1) {
                    // deinit takes an argument (likely allocator)
                    for (self.vectors.items) |*vector| {
                        vector.deinit(self.allocator);
                    }
                } else {
                    // deinit takes no arguments beyond self
                    for (self.vectors.items) |*vector| {
                        vector.deinit();
                    }
                }
            } else {
                std.log.warn("TestVectorList: type " ++ @typeName(T) ++ " does not have a deinit method");
            }
            self.vectors.deinit();
            self.* = undefined;
        }

        /// Add a single test vector to the list
        pub fn append(self: *Self, vector: T) !void {
            try self.vectors.append(vector);
        }
    };
}

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

        const vector = try loader.loadAndDeserializeTestVector(T, params, allocator, entry.path);
        try vectors.append(vector);
    }

    return vectors;
}
