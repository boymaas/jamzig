const std = @import("std");
const safrole = @import("./libs/safrole.zig");

const TestVectors = struct {
    test_vectors: std.ArrayList(std.json.Parsed(safrole.TestVector)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TestVectors {
        var self: TestVectors = undefined;
        self.test_vectors = std.ArrayList(std.json.Parsed(safrole.TestVector)).init(allocator);
        self.allocator = allocator;
        return self;
    }

    pub fn append(self: *TestVectors, test_vector: std.json.Parsed(safrole.TestVector)) !void {
        try self.test_vectors.append(test_vector);
    }

    pub fn deinit(self: *TestVectors) void {
        // deinit the individual test vectots
        for (self.test_vectors.items) |test_vector| {
            test_vector.deinit();
        }
        self.test_vectors.deinit();
    }
};

/// Read a directory, find all the JSON files, and try to build a TestVector from them.
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
        // check if its a json file
        if (std.mem.endsWith(u8, entry.name, ".json") == false) {
            continue;
        }

        std.debug.print("Reading file: {s}\n", .{entry.name});

        const paths = [_][]const u8{ path, entry.name };
        const json_file_path = try std.fs.path.join(allocator, &paths);
        defer allocator.free(json_file_path);
        //
        const test_vector = try safrole.TestVector.build_from(allocator, json_file_path);
        try test_vectors.append(test_vector);
    }

    return test_vectors;
}

test "Load and dump a tiny test vector, and check the outputs" {
    const allocator = std.testing.allocator;

    const test_jsons: [4][]const u8 = .{
        "tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-1.json",
        "tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-4.json",
        "tests/vectors/safrole/safrole/tiny/publish-tickets-no-mark-9.json",
        "tests/vectors/safrole/safrole/tiny/publish-tickets-with-mark-4.json",
    };

    // const stdout = std.io.getStdOut().writer();
    for (test_jsons) |test_json| {
        const test_vector = try safrole.TestVector.build_from(allocator, test_json);
        defer test_vector.deinit();

        std.debug.print("Test vector: {?}\n", .{test_vector.value.output});

        // try std.json.stringify(test_vector.value.output, .{ .whitespace = .indent_1 }, stdout);
    }
}

test "Correct parsing of all tiny test vectors" {
    const allocator = std.testing.allocator;

    var test_vectors = try buildTestVectors(allocator, "tests/vectors/safrole/safrole/tiny/");
    defer test_vectors.deinit();
}

test "Correct parsing of all full test vectors" {
    const allocator = std.testing.allocator;

    var test_vectors = try buildTestVectors(allocator, "tests/vectors/safrole/safrole/full/");
    defer test_vectors.deinit();
}
