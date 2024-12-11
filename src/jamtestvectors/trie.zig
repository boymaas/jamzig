const std = @import("std");

const Dict = std.AutoHashMap([32]u8, []const u8);

pub const TrieTest = struct {
    input: std.json.Value,
    output: [64]u8,
};

pub const ParsedTrieTest = struct {
    input: Dict,
    output: [32]u8,
    allocator: std.mem.Allocator,

    pub fn parse(trie_test: *const TrieTest, allocator: std.mem.Allocator) !ParsedTrieTest {
        var dict = Dict.init(allocator);
        errdefer dict.deinit();

        var entries = trie_test.input.object.iterator();
        while (entries.next()) |entry| {
            var key: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&key, entry.key_ptr.*);

            const value_string = entry.value_ptr.*.string;
            const value = try allocator.alloc(u8, value_string.len / 2);
            errdefer allocator.free(value);

            _ = try std.fmt.hexToBytes(value, value_string);
            try dict.put(key, value);
        }

        var output: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&output, &trie_test.output);

        return .{
            .input = dict,
            .output = output,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParsedTrieTest) void {
        // iterate ove the values of input and free them
        var values = self.input.valueIterator();
        while (values.next()) |value| {
            self.allocator.free(value.*);
        }
        self.input.deinit();
    }
};

pub const TrieTestVector = struct {
    tests: []ParsedTrieTest,

    allocator: std.mem.Allocator,

    /// Build the vector from the JSON file. The binary is loaded by stripping the JSON
    /// and using the bin extension to load the binary associated as the expected binary format,
    /// to which serialization and deserialization should conform.
    pub fn build_from(
        allocator: std.mem.Allocator,
        json_path: []const u8,
    ) !TrieTestVector {
        const file = try std.fs.cwd().openFile(json_path, .{});
        defer file.close();

        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        // configure json scanner to track diagnostics for easier debugging
        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        // parse from tokensource using the scanner
        const trie_tests = std.json.parseFromTokenSource(
            []TrieTest,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse TrieTest [{s}]: {}\n{any}", .{ json_path, err, diagnostics });
            return err;
        };
        defer trie_tests.deinit();

        var parsed_trie_tests = try allocator.alloc(ParsedTrieTest, trie_tests.value.len);
        errdefer allocator.free(parsed_trie_tests);
        for (trie_tests.value, 0..) |trie_test, i| {
            parsed_trie_tests[i] = ParsedTrieTest.parse(&trie_test, allocator) catch |err| {
                std.debug.print("Failed to parse TrieTest: {}\n", .{err});
                return err;
            };
        }

        return .{
            .tests = parsed_trie_tests,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        for (self.tests) |*parsed_test| {
            parsed_test.deinit();
        }
    }
};

test "test:vectors:trie: parsing the test vector" {
    const allocator = std.heap.page_allocator;
    const vector = try TrieTestVector.build_from(allocator, "src/jamtestvectors/data/trie/trie.json");
    defer vector.deinit();

    std.debug.print("Loaded test vector with {} tests\n", .{vector.tests.len});

    for (vector.tests) |trie_test| {
        std.debug.print("Parsed test vector with {} entries\n", .{trie_test.input.count()});
    }

    // Test if the vector contains the binary type
    try std.testing.expectEqual(11, vector.tests.len);
}
