const std = @import("std");
const TrieTestVector = @import("jamtestvectors//trie.zig").TrieTestVector;
const merkle = @import("merkle.zig");

test "merkle:test_vectors" {
    const allocator = std.heap.page_allocator;
    const vector = try TrieTestVector.build_from(allocator, "src/tests/vectors/trie/trie/trie.json");
    defer vector.deinit();

    for (vector.tests, 0..) |trie_test, idx| {
        std.debug.print("Running merkle test {}...", .{idx});

        var entries = trie_test.input.iterator();

        var e = std.ArrayList(merkle.Entry).init(allocator);
        defer e.deinit();

        while (entries.next()) |entry| {
            try e.append(merkle.Entry{ .k = entry.key_ptr.*, .v = entry.value_ptr.* });
        }

        const commitment = try merkle.M_sigma(allocator, e.items);

        try std.testing.expectEqual(trie_test.output, commitment);
        std.debug.print("OK\n", .{});
    }
}
