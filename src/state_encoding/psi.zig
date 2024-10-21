const std = @import("std");

const types = @import("../types.zig");

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const disputes = @import("../disputes.zig");
const Psi = disputes.Psi;
const Hash = disputes.Hash;

pub fn encode(self: *const Psi, writer: anytype) !void {
    // Encode good_set
    try encodeOrderedSet(&self.good_set, writer);

    // Encode bad_set
    try encodeOrderedSet(&self.bad_set, writer);

    // Encode wonky_set
    try encodeOrderedSet(&self.wonky_set, writer);

    // Encode punish_set
    try encodeOrderedSet(&self.punish_set, writer);
}

// For sorting a small list, insertion sort is generally the best choice among these options. Here's why:
//
// 1. Simplicity: Insertion sort is straightforward and has low overhead, which is beneficial for small datasets.
// 2. Performance on small lists: For small n, the O(n^2) worst-case complexity of insertion sort is not a significant issue, and it often outperforms more complex algorithms due to its simplicity and good cache performance.
// 3. Adaptive behavior: Insertion sort performs exceptionally well on nearly sorted data, which is common in many real-world scenarios.
// 4. In-place sorting: It sorts the list in-place, requiring only O(1) extra space.

fn _lessThanU8_32_(_: void, a: [32]u8, b: [32]u8) bool {
    return std.mem.lessThan(u8, &a, &b);
}

fn encodeOrderedSet(set: *const std.AutoHashMap([32]u8, void), writer: anytype) !void {
    var list = std.ArrayList(Hash).init(set.allocator);
    defer list.deinit();

    var it = set.keyIterator();
    while (it.next()) |key| {
        try list.append(key.*);
    }

    std.sort.insertion(Hash, list.items, {}, _lessThanU8_32_);

    try writer.writeAll(encoder.encodeInteger(@intCast(list.items.len)).as_slice());
    for (list.items) |hash| {
        try writer.writeAll(&hash);
    }
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

const testing = std.testing;

test "encode" {
    const allocator = std.testing.allocator;
    var psi = Psi.init(allocator);
    defer psi.deinit();

    // Add items to the sets in unsorted order
    try psi.good_set.put([_]u8{3} ** 32, {});
    try psi.good_set.put([_]u8{1} ** 32, {});
    try psi.good_set.put([_]u8{2} ** 32, {});
    try psi.good_set.put([_]u8{8} ** 32, {});
    try psi.good_set.put([_]u8{0} ** 32, {});

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encode(&psi, buffer.writer());

    const decoder = @import("../codec/decoder.zig");

    // Decode the buffer
    var reader = buffer.items;
    const decoded = try decoder.decodeInteger(reader);
    try testing.expectEqual(@as(usize, 5), decoded.value);

    reader = reader[decoded.bytes_read..];

    var prev_hash: ?*Hash = null;
    var i: usize = 0;
    while (i < decoded.value) : (i += 1) {
        const hash = reader[0..32];

        if (prev_hash) |ph| {
            try testing.expect(std.mem.lessThan(u8, ph, hash));
        }
        prev_hash = hash;
        reader = reader[32..];
    }
}
