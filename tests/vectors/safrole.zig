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

// read a dir find all the json files and try to build a TestVector from them.
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

test "Correct parsing of all test vectors" {
    const allocator = std.testing.allocator;

    // const test_vector = try safrole.TestVector.build_from(allocator, "tests/vectors/jam/safrole/tiny/publish-tickets-no-mark-1.json");
    // defer test_vector.deinit();

    var test_vectors = try buildTestVectors(allocator, "tests/vectors/jam/safrole/tiny/");
    defer test_vectors.deinit();

    // std.debug.print("Test vector: {}\n", .{test_vector.value.input.entropy});
    // std.debug.print("Test vector: {any}\n", .{test_vector.value.input.extrinsic[1]});
    // std.debug.print("Test vector: {}\n", .{test_vector.value});

    // stringify the JSON string
    // const stdout = std.io.getStdOut().writer();
    // try std.json.stringify(test_vector.value, .{ .whitespace = .indent_2 }, stdout);
}
