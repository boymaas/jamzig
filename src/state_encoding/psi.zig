const std = @import("std");
const types = @import("../types.zig");

const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");

const disputes = @import("../disputes.zig");
const Psi = disputes.Psi;
const Hash = disputes.Hash;

const trace = @import("../tracing.zig").scoped(.codec);

pub fn encode(self: *const Psi, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting PSI state encoding", .{});

    // Encode each set
    try encodeOrderedSet(&self.good_set, "good", writer);
    try encodeOrderedSet(&self.bad_set, "bad", writer);
    try encodeOrderedSet(&self.wonky_set, "wonky", writer);
    try encodeOrderedSet(&self.punish_set, "punish", writer);

    span.debug("Successfully encoded all PSI sets", .{});
}

const makeLessThanSliceOfFn = @import("../utils/sort.zig").makeLessThanSliceOfFn;
const lessThanSliceOfHashes = makeLessThanSliceOfFn([32]u8);

fn encodeOrderedSet(set: *const std.AutoArrayHashMap([32]u8, void), name: []const u8, writer: anytype) !void {
    const span = trace.span(.encode_ordered_set);
    defer span.deinit();
    span.debug("Encoding ordered set: {s}", .{name});
    span.trace("Set size: {d} items", .{set.count()});

    var list = std.ArrayList(Hash).init(set.allocator);
    defer list.deinit();

    try list.appendSlice(set.keys());
    span.debug("Created temporary list for sorting", .{});

    std.sort.insertion(Hash, list.items, {}, lessThanSliceOfHashes);
    span.debug("Sorted hash list", .{});

    try writer.writeAll(encoder.encodeInteger(@intCast(list.items.len)).as_slice());
    span.trace("Wrote length prefix: {d}", .{list.items.len});

    for (list.items, 0..) |hash, i| {
        const item_span = span.child(.hash_item);
        defer item_span.deinit();
        item_span.trace("Writing hash {d} of {d}: {any}", .{ i + 1, list.items.len, std.fmt.fmtSliceHexLower(&hash) });
        try writer.writeAll(&hash);
    }

    span.debug("Successfully encoded ordered set: {s}", .{name});
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
