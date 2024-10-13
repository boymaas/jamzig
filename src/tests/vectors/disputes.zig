const std = @import("std");
const disputes = @import("./libs/disputes.zig");

const TestVectors = struct {
    test_vectors: std.ArrayList(std.json.Parsed(disputes.TestVector)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TestVectors {
        var self: TestVectors = undefined;
        self.test_vectors = std.ArrayList(std.json.Parsed(disputes.TestVector)).init(allocator);
        self.allocator = allocator;
        return self;
    }

    pub fn append(self: *TestVectors, test_vector: std.json.Parsed(disputes.TestVector)) !void {
        try self.test_vectors.append(test_vector);
    }

    pub fn deinit(self: *TestVectors) void {
        for (self.test_vectors.items) |test_vector| {
            test_vector.deinit();
        }
        self.test_vectors.deinit();
    }
};

fn buildTestVectors(allocator: std.mem.Allocator, path: []const u8) !TestVectors {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var test_vectors = try TestVectors.init(allocator);
    errdefer test_vectors.deinit();

    var files = dir.iterate();

    while (try files.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (std.mem.endsWith(u8, entry.name, ".json") == false) {
            continue;
        }

        std.debug.print("Reading file: {s}{s}\n", .{ path, entry.name });

        const paths = [_][]const u8{ path, entry.name };
        const json_file_path = try std.fs.path.join(allocator, &paths);
        defer allocator.free(json_file_path);

        const test_vector = try disputes.TestVector.build_from(allocator, json_file_path);
        try test_vectors.append(test_vector);
    }

    return test_vectors;
}

test "Load and dump a tiny test vector, and check the outputs" {
    const allocator = std.testing.allocator;

    const test_jsons: [1][]const u8 = .{
        "src/tests/vectors/disputes/disputes/tiny/progress_with_no_verdicts-1.json",
    };

    for (test_jsons) |test_json| {
        const test_vector = try disputes.TestVector.build_from(allocator, test_json);
        defer test_vector.deinit();

        std.debug.print("Test vector: {?}\n", .{test_vector.value.output});
    }
}

test "Correct parsing of all tiny test vectors" {
    const allocator = std.testing.allocator;

    var test_vectors = try buildTestVectors(allocator, "src/tests/vectors/disputes/disputes/tiny/");
    defer test_vectors.deinit();
}

test "Correct parsing of all full test vectors" {
    const allocator = std.testing.allocator;

    var test_vectors = try buildTestVectors(allocator, "src/tests/vectors/disputes/disputes/full/");
    defer test_vectors.deinit();
}
