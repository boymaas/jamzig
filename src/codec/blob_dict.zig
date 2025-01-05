/// This to read primarly the jamtestnet binary blobs to rebuild a jamstate from a state dump.
const std = @import("std");

const readInteger = @import("../codec.zig").readInteger;
const writeInteger = @import("../codec.zig").writeInteger;

const log = @import("../tracing.zig").scoped(.blob_dict);

/// A dictionary mapping 32-byte keys to variable-length binary blobs
pub const BlobDict = struct {
    map: std.AutoArrayHashMap([32]u8, []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BlobDict {
        const span = log.span(.init);
        defer span.deinit();
        span.debug("Initializing new BlobDict", .{});

        return .{
            .map = std.AutoArrayHashMap([32]u8, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn decode(_: anytype, reader: anytype, alloc: std.mem.Allocator) !@This() {
        return try deserializeDict(alloc, reader);
    }

    pub fn deinit(self: *BlobDict) void {
        const span = log.span(.deinit);
        defer span.deinit();
        span.debug("Deinitializing BlobDict", .{});
        span.trace("Current entry count: {d}", .{self.map.count()});

        // Free all value blobs
        for (self.map.values()) |value| {
            span.trace("Freeing value of length {d}", .{value.len});
            self.allocator.free(value);
        }
        self.map.deinit();
        span.debug("Successfully freed all resources", .{});
        self.* = undefined;
    }
};

pub fn deserializeDict(allocator: std.mem.Allocator, reader: anytype) !BlobDict {
    const span = log.span(.deserialize);
    defer span.deinit();
    span.debug("Starting dictionary deserialization", .{});

    var dict = BlobDict.init(allocator);
    errdefer {
        span.err("Error during deserialization, cleaning up", .{});
        dict.deinit();
    }

    // Read number of entries
    const count = try readInteger(reader);
    span.debug("Reading dictionary with {d} entries", .{count});

    // Read each key-value pair in sorted order
    var prev_key: ?[32]u8 = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry_span = span.child(.entry);
        defer entry_span.deinit();
        entry_span.debug("Processing entry {d}/{d}", .{ i + 1, count });

        // Read fixed-size key
        var key: [32]u8 = undefined;
        try reader.readNoEof(&key);
        entry_span.debug("Read key", .{});
        entry_span.trace("Key bytes: {s}", .{std.fmt.fmtSliceHexLower(&key)});

        // Verify keys are in ascending order
        if (prev_key) |pk| {
            const order_span = entry_span.child(.order_check);
            defer order_span.deinit();
            order_span.trace("Previous key: {s}", .{std.fmt.fmtSliceHexLower(&pk)});
            order_span.trace("Current key: {s}", .{std.fmt.fmtSliceHexLower(&key)});

            if (!std.mem.lessThan(u8, &pk, &key)) {
                order_span.err("Key ordering violation detected", .{});
                order_span.trace("Previous key ({s}) >= Current key ({s})", .{
                    std.fmt.fmtSliceHexLower(&pk),
                    std.fmt.fmtSliceHexLower(&key),
                });
                return error.KeysNotSorted;
            }
            order_span.debug("Key order verified", .{});
        }
        prev_key = key;

        // Read value length and data
        const value_len = try readInteger(reader);
        entry_span.debug("Reading value of length {d} bytes", .{value_len});

        const value = try allocator.alloc(u8, @intCast(value_len));
        errdefer {
            entry_span.err("Error while reading value, freeing buffer", .{});
            allocator.free(value);
        }

        try reader.readNoEof(value);

        if (value_len < 32) {
            entry_span.trace("Value contents: {s}", .{std.fmt.fmtSliceHexLower(value)});
        } else {
            entry_span.trace("Value prefix (32/{d} bytes): {s}...", .{
                value_len,
                std.fmt.fmtSliceHexLower(value[0..32]),
            });
        }

        // Value will be owned by the dictionary after put()
        try dict.map.put(key, value);
        entry_span.debug("Entry successfully added to dictionary", .{});
    }

    span.debug("Dictionary deserialization complete", .{});
    span.trace("Final entry count: {d}", .{count});
    return dict;
}

//  _   _       _ _   _            _
// | | | |_ __ (_) |_| |_ ___  ___| |_ ___
// | | | | '_ \| | __| __/ _ \/ __| __/ __|
// | |_| | | | | | |_| ||  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__|\__\___||___/\__|___/

const testing = std.testing;

test "BlobDict - basic operations" {
    const span = log.span(.test_basic);
    defer span.deinit();

    const allocator = testing.allocator;
    var dict = BlobDict.init(allocator);
    defer dict.deinit();

    span.debug("Testing empty dictionary", .{});
    try testing.expectEqual(@as(usize, 0), dict.map.count());

    // Create test data
    const key1 = [_]u8{1} ** 32;
    const value1 = "test value 1";
    const key2 = [_]u8{2} ** 32;
    const value2 = "test value 2";

    span.debug("Testing put operations", .{});
    {
        const put_span = span.child(.put_test);
        defer put_span.deinit();

        const v1 = try allocator.dupe(u8, value1);
        try dict.map.put(key1, v1);
        put_span.trace("Added first entry - key: {s}", .{std.fmt.fmtSliceHexLower(&key1)});

        const v2 = try allocator.dupe(u8, value2);
        try dict.map.put(key2, v2);
        put_span.trace("Added second entry - key: {s}", .{std.fmt.fmtSliceHexLower(&key2)});

        try testing.expectEqual(@as(usize, 2), dict.map.count());
        try testing.expectEqualStrings(value1, dict.map.get(key1).?);
        try testing.expectEqualStrings(value2, dict.map.get(key2).?);
        put_span.debug("Put operations verified", .{});
    }

    span.debug("Testing non-existent key lookup", .{});
    const missing_key = [_]u8{3} ** 32;
    try testing.expect(dict.map.get(missing_key) == null);
    span.trace("Missing key test passed: {s}", .{std.fmt.fmtSliceHexLower(&missing_key)});
}

test "BlobDict - serialization and deserialization" {
    const span = log.span(.test_serialization);
    defer span.deinit();

    const allocator = testing.allocator;

    span.debug("Creating test dictionary", .{});
    var dict = BlobDict.init(allocator);
    defer dict.deinit();

    // Create test data with keys in ascending order
    const key1 = [_]u8{1} ** 32;
    const value1 = "test value 1";
    const key2 = [_]u8{2} ** 32;
    const value2 = "test value 2";

    {
        const setup_span = span.child(.setup);
        defer setup_span.deinit();

        const v1 = try allocator.dupe(u8, value1);
        try dict.map.put(key1, v1);
        setup_span.trace("Added first entry - key: {s}, value: {s}", .{
            std.fmt.fmtSliceHexLower(&key1),
            value1,
        });

        const v2 = try allocator.dupe(u8, value2);
        try dict.map.put(key2, v2);
        setup_span.trace("Added second entry - key: {s}, value: {s}", .{
            std.fmt.fmtSliceHexLower(&key2),
            value2,
        });
    }

    span.debug("Creating serialization buffer", .{});
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    // Serialize
    const serialize_span = span.child(.serialize);
    defer serialize_span.deinit();

    try writeInteger(dict.map.count(), writer);
    serialize_span.trace("Wrote entry count: {d}", .{dict.map.count()});

    var it = dict.map.iterator();
    while (it.next()) |entry| {
        try writer.writeAll(&entry.key_ptr.*);
        try writeInteger(entry.value_ptr.len, writer);
        try writer.writeAll(entry.value_ptr.*);
        serialize_span.trace("Wrote entry - key: {s}, value length: {d}", .{
            std.fmt.fmtSliceHexLower(entry.key_ptr),
            entry.value_ptr.len,
        });
    }
    serialize_span.debug("Serialization complete", .{});

    // Deserialize
    const deserialize_span = span.child(.deserialize);
    defer deserialize_span.deinit();

    var stream = std.io.fixedBufferStream(buf.items);
    const reader = stream.reader();
    var deserialized = try deserializeDict(allocator, reader);
    defer deserialized.deinit();

    deserialize_span.debug("Verifying deserialized contents", .{});
    try testing.expectEqual(@as(usize, 2), deserialized.map.count());
    try testing.expectEqualStrings(value1, deserialized.map.get(key1).?);
    try testing.expectEqualStrings(value2, deserialized.map.get(key2).?);
    deserialize_span.debug("Verification successful", .{});
}

test "BlobDict - error cases" {
    const span = log.span(.test_errors);
    defer span.deinit();

    const allocator = testing.allocator;

    // Test case 1: Keys not in ascending order
    {
        const order_span = span.child(.order_test);
        defer order_span.deinit();
        order_span.debug("Testing key ordering violation", .{});

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

        order_span.trace("Writing first entry - key: {s}", .{std.fmt.fmtSliceHexLower(&key1)});
        try writer.writeAll(&key1);
        try writeInteger(value1.len, writer);
        try writer.writeAll(value1);

        order_span.trace("Writing second entry - key: {s}", .{std.fmt.fmtSliceHexLower(&key2)});
        try writer.writeAll(&key2);
        try writeInteger(value2.len, writer);
        try writer.writeAll(value2);

        var stream = std.io.fixedBufferStream(buf.items);
        const reader = stream.reader();

        try testing.expectError(error.KeysNotSorted, deserializeDict(allocator, reader));
        order_span.debug("Key ordering violation detected as expected", .{});
    }

    // Test case 2: Incomplete data
    {
        const incomplete_span = span.child(.incomplete_test);
        defer incomplete_span.deinit();
        incomplete_span.debug("Testing incomplete data handling", .{});

        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        // Write count but no data
        try writeInteger(1, writer);
        incomplete_span.trace("Wrote entry count: 1, but no entry data", .{});

        var stream = std.io.fixedBufferStream(buf.items);
        const reader = stream.reader();

        try testing.expectError(error.EndOfStream, deserializeDict(allocator, reader));
        incomplete_span.debug("EndOfStream error detected as expected", .{});
    }
}
