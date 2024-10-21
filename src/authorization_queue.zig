///
/// Authorization Queue (φ) Implementation
///
/// This module implements the Authorization Queue (φ) as specified in the Jam protocol.
/// φ is a critical component of the state, maintaining pending authorizations for each core.
///
/// Key features:
/// - Maintains C separate queues, one for each core.
/// - Each queue can hold up to Q authorization hashes.
/// - Authorizations are 32-byte hashes.
/// - Supports adding and removing authorizations for each core.
///
const std = @import("std");

// Constants
const C: usize = 341; // Number of cores
const Q: usize = 80; // Maximum number of items in the authorizations queue
const H: usize = 32; // Hash size

const AuthorizerHash = [32]u8;

// Define the AuthorizationQueue type
pub const Phi = struct {
    queue: [C]std.ArrayList(AuthorizerHash),
    allocator: std.mem.Allocator,

    // Hash type (32 bytes)

    // Initialize the AuthorizationQueue
    pub fn init(allocator: std.mem.Allocator) !Phi {
        var queue: [C]std.ArrayList(AuthorizerHash) = undefined;
        for (0..C) |i| {
            queue[i] = std.ArrayList(AuthorizerHash).init(allocator);
        }
        return Phi{ .queue = queue, .allocator = allocator };
    }

    // Deinitialize the AuthorizationQueue
    pub fn deinit(self: *Phi) void {
        for (0..C) |i| {
            self.queue[i].deinit();
        }
    }

    const encoder = @import("codec/encoder.zig");

    pub fn encode(self: *const Phi, writer: anytype) !void {
        // The number of cores (C) is a constant no need to encode it
        // Encode each queue
        for (self.queue) |core_queue| {
            // The length of the queue is not encoded as it is a Constants
            // Encode each hash in the queue
            for (core_queue.items) |hash| {
                try writer.writeAll(&hash);
            }
            // Write 0 hashes to fill the queue until 80
            const zero_hashes_to_write = Q - core_queue.items.len;
            const zero_hash = [_]u8{0} ** H;
            var i: usize = 0;
            while (i < zero_hashes_to_write) : (i += 1) {
                try writer.writeAll(&zero_hash);
            }
        }
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("queue");
        try jw.beginArray();
        for (self.queue) |core_queue| {
            try jw.beginArray();
            for (core_queue.items) |hash| {
                var hex_buf: [H * 2]u8 = undefined;
                const queue = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
                try jw.write(queue);
            }
            try jw.endArray();
        }
        try jw.endArray();
        try jw.endObject();
    }

    // Add an authorization to the queue for a specific core
    pub fn addAuthorization(self: *Phi, core: usize, hash: AuthorizerHash) !void {
        if (core >= C) return error.InvalidCore;
        if (self.queue[core].items.len >= Q) return error.QueueFull;
        try self.queue[core].append(hash);
    }

    // Remove and return the first authorization from the queue for a specific core
    pub fn popAuthorization(self: *Phi, core: usize) ?AuthorizerHash {
        if (core >= C) return null;
        if (self.queue[core].items.len == 0) return null;
        return self.queue[core].orderedRemove(0);
    }

    // Get the number of authorizations in the queue for a specific core
    pub fn getQueueLength(self: *Phi, core: usize) usize {
        if (core >= C) return 0;
        return self.queue[core].items.len;
    }
};

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_ ___
// | | | | '_ \| | __|| |/ _ \/ __| __/ __|
// | |_| | | | | | |_ | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__||_|\___||___/\__|___/
//

const testing = std.testing;

test "AuthorizationQueue - initialization and deinitialization" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    try testing.expectEqual(@as(usize, C), auth_queue.queue.len);
    for (auth_queue.queue) |queue| {
        try testing.expectEqual(@as(usize, 0), queue.items.len);
    }
}

test "AuthorizationQueue - add and pop authorizations" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Add to core 0
    try auth_queue.addAuthorization(0, test_hash);
    try testing.expectEqual(@as(usize, 1), auth_queue.getQueueLength(0));

    // Pop from core 0
    const popped_hash = auth_queue.popAuthorization(0);
    try testing.expect(popped_hash != null);
    try testing.expectEqualSlices(u8, &test_hash, &popped_hash.?);
    try testing.expectEqual(@as(usize, 0), auth_queue.getQueueLength(0));
}

test "AuthorizationQueue - queue full error" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Fill the queue
    for (0..Q) |_| {
        try auth_queue.addAuthorization(0, test_hash);
    }

    // Try to add one more
    try testing.expectError(error.QueueFull, auth_queue.addAuthorization(0, test_hash));
}

test "AuthorizationQueue - invalid core error" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    try testing.expectError(error.InvalidCore, auth_queue.addAuthorization(C, test_hash));
    try testing.expect(auth_queue.popAuthorization(C) == null);
    try testing.expectEqual(@as(usize, 0), auth_queue.getQueueLength(C));
}

test "AuthorizationQueue - multiple cores" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;

    try auth_queue.addAuthorization(0, test_hash1);
    try auth_queue.addAuthorization(1, test_hash2);

    try testing.expectEqual(@as(usize, 1), auth_queue.getQueueLength(0));
    try testing.expectEqual(@as(usize, 1), auth_queue.getQueueLength(1));

    const popped_hash1 = auth_queue.popAuthorization(0);
    const popped_hash2 = auth_queue.popAuthorization(1);

    try testing.expectEqualSlices(u8, &test_hash1, &popped_hash1.?);
    try testing.expectEqualSlices(u8, &test_hash2, &popped_hash2.?);
}

test "AuthorizationQueue - pop from empty queue" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    try testing.expect(auth_queue.popAuthorization(0) == null);
}

test "AuthorizationQueue - FIFO order" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;
    const test_hash3 = [_]u8{3} ** H;

    try auth_queue.addAuthorization(0, test_hash1);
    try auth_queue.addAuthorization(0, test_hash2);
    try auth_queue.addAuthorization(0, test_hash3);

    try testing.expectEqualSlices(u8, &test_hash1, &auth_queue.popAuthorization(0).?);
    try testing.expectEqualSlices(u8, &test_hash2, &auth_queue.popAuthorization(0).?);
    try testing.expectEqualSlices(u8, &test_hash3, &auth_queue.popAuthorization(0).?);
}

test "AuthorizationQueue - encode function" {
    var auth_queue = try Phi.init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;

    try auth_queue.addAuthorization(0, test_hash1);
    try auth_queue.addAuthorization(1, test_hash2);

    var buf: [C * Q * H]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try auth_queue.encode(fbs.writer());

    // Check the first core's hash
    try testing.expectEqualSlices(u8, &test_hash1, buf[0..H]);

    // Check the second core's hash
    try testing.expectEqualSlices(u8, &test_hash2, buf[Q * H .. Q * H + H]);

    // Check that the rest is zeroed
    for (buf[H .. Q * H]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    for (buf[Q * H + H ..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // Check that all other entries in the map are zero
    for (2..C) |core| {
        const start = core * Q * H;
        const end = start + Q * H;
        for (buf[start..end]) |byte| {
            try testing.expectEqual(@as(u8, 0), byte);
        }
    }

    // Check the total size matches
    try testing.expectEqual(@as(usize, C * Q * H), buf.len);
}
