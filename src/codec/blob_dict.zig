/// This to read primarly the jamtestnet binary blobs to rebuild a jamstate from a state dump.
const std = @import("std");

const readInteger = @import("../codec.zig").readInteger;
const writeInteger = @import("../codec.zig").writeInteger;

/// A dictionary mapping 32-byte keys to variable-length binary blobs
pub const BlobDict = struct {
    map: std.AutoArrayHashMap([32]u8, []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BlobDict {
        return .{
            .map = std.AutoArrayHashMap([32]u8, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BlobDict) void {
        // Free all value blobs

        for (self.map.values()) |value| {
            self.allocator.free(value);
        }
        self.map.deinit();
    }
};

pub fn deserializeDict(allocator: std.mem.Allocator, reader: anytype) !BlobDict {
    var dict = BlobDict.init(allocator);
    errdefer dict.deinit();

    // Read number of entries
    const count = try readInteger(reader);

    // Read each key-value pair in sorted order
    var prev_key: ?[32]u8 = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Read fixed-size key
        var key: [32]u8 = undefined;
        try reader.readNoEof(&key);

        // Verify keys are in ascending order
        if (prev_key) |pk| {
            if (!std.mem.lessThan(u8, &pk, &key)) {
                return error.KeysNotSorted;
            }
        }
        prev_key = key;

        // Read value length and data
        const value_len = try readInteger(reader);
        const value = try allocator.alloc(u8, @intCast(value_len));
        errdefer allocator.free(value);
        try reader.readNoEof(value);

        // Value will be owned by the dictionary after put()
        try dict.map.put(key, value);
    }

    return dict;
}

//  _   _       _ _   _            _
// | | | |_ __ (_) |_| |_ ___  ___| |_ ___
// | | | | '_ \| | __| __/ _ \/ __| __/ __|
// | |_| | | | | | |_| ||  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__|\__\___||___/\__|___/

const testing = std.testing;

test "BlobDict - basic operations" {
    const allocator = testing.allocator;
    var dict = BlobDict.init(allocator);
    defer dict.deinit();

    // Test empty dict
    try testing.expectEqual(@as(usize, 0), dict.map.count());

    // Create test data
    const key1 = [_]u8{1} ** 32;
    const value1 = "test value 1";
    const key2 = [_]u8{2} ** 32;
    const value2 = "test value 2";

    // Test putting and getting values
    {
        const v1 = try allocator.dupe(u8, value1);
        try dict.map.put(key1, v1);
        const v2 = try allocator.dupe(u8, value2);
        try dict.map.put(key2, v2);

        try testing.expectEqual(@as(usize, 2), dict.map.count());
        try testing.expectEqualStrings(value1, dict.map.get(key1).?);
        try testing.expectEqualStrings(value2, dict.map.get(key2).?);
    }

    // Test non-existent key returns null
    const missing_key = [_]u8{3} ** 32;
    try testing.expect(dict.map.get(missing_key) == null);
}

test "BlobDict - serialization and deserialization" {
    const allocator = testing.allocator;

    // Create and populate original dictionary
    var dict = BlobDict.init(allocator);
    defer dict.deinit();

    // Create test data with keys in ascending order
    const key1 = [_]u8{1} ** 32;
    const value1 = "test value 1";
    const key2 = [_]u8{2} ** 32;
    const value2 = "test value 2";

    {
        const v1 = try allocator.dupe(u8, value1);
        try dict.map.put(key1, v1);
        const v2 = try allocator.dupe(u8, value2);
        try dict.map.put(key2, v2);
    }

    // Create a buffer to serialize into
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    // Serialize
    try writeInteger(dict.map.count(), writer);
    var it = dict.map.iterator();
    while (it.next()) |entry| {
        try writer.writeAll(&entry.key_ptr.*);
        try writeInteger(entry.value_ptr.len, writer);
        try writer.writeAll(entry.value_ptr.*);
    }

    // Deserialize
    var stream = std.io.fixedBufferStream(buf.items);
    const reader = stream.reader();
    var deserialized = try deserializeDict(allocator, reader);
    defer deserialized.deinit();

    // Verify deserialized contents
    try testing.expectEqual(@as(usize, 2), deserialized.map.count());
    try testing.expectEqualStrings(value1, deserialized.map.get(key1).?);
    try testing.expectEqualStrings(value2, deserialized.map.get(key2).?);
}

test "BlobDict - error cases" {
    const allocator = testing.allocator;

    // Test case 1: Keys not in ascending order
    {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        // Write count
        try writeInteger(2, writer);

        // Write key-value pairs in wrong order
        const key1 = [_]u8{2} ** 32; // Higher key first
        const value1 = "test1";
        const key2 = [_]u8{1} ** 32; // Lower key second
        const value2 = "test2";

        try writer.writeAll(&key1);
        try writeInteger(value1.len, writer);
        try writer.writeAll(value1);

        try writer.writeAll(&key2);
        try writeInteger(value2.len, writer);
        try writer.writeAll(value2);

        var stream = std.io.fixedBufferStream(buf.items);
        const reader = stream.reader();

        try testing.expectError(error.KeysNotSorted, deserializeDict(allocator, reader));
    }

    // Test case 2: Incomplete data
    {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        // Write count but no data
        try writeInteger(1, writer);

        var stream = std.io.fixedBufferStream(buf.items);
        const reader = stream.reader();

        try testing.expectError(error.EndOfStream, deserializeDict(allocator, reader));
    }
}
