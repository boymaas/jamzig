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

const AuthorizerHash = [32]u8;

// TODO: Authorization to Authorizer
// Define the AuthorizationQueue type
pub fn Phi(
    comptime core_count: u16,
    comptime max_authorizations_queue_items: u8, // Q
) type {
    return struct {
        queue: [core_count]std.ArrayList(AuthorizerHash),
        allocator: std.mem.Allocator,

        max_authorizations_queue_items: u8 = max_authorizations_queue_items,

        // Initialize the AuthorizationQueue
        pub fn init(allocator: std.mem.Allocator) !Phi(core_count, max_authorizations_queue_items) {
            var queue: [core_count]std.ArrayList(AuthorizerHash) = undefined;
            for (0..core_count) |i| {
                queue[i] = std.ArrayList(AuthorizerHash).init(allocator);
            }
            return .{ .queue = queue, .allocator = allocator };
        }

        // Create a deep copy of the AuthorizationQueue
        pub fn deepClone(self: *const @This()) !@This() {
            // Initialize a new queue with the same allocator
            var cloned: @This() = .{
                .allocator = self.allocator,
                .queue = undefined,
            };

            // Deep copy each core's queue
            for (0..core_count) |i| {
                // Create a new ArrayList with exact capacity needed
                cloned.queue[i] = try self.queue[i].clone();
            }

            return cloned;
        }

        // Deinitialize the AuthorizationQueue
        pub fn deinit(self: *@This()) void {
            for (0..core_count) |i| {
                self.queue[i].deinit();
            }
            self.* = undefined;
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/authorization_queue.zig").jsonStringify(self, jw);
        }

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/phi.zig").format(
                core_count,
                max_authorizations_queue_items,
                self,
                fmt,
                options,
                writer,
            );
        }

        // Add an authorization to the queue for a specific core
        pub fn addAuthorization(self: *@This(), core: usize, hash: AuthorizerHash) !void {
            if (core >= core_count) return error.InvalidCore;
            if (self.queue[core].items.len >= max_authorizations_queue_items) return error.QueueFull;
            try self.queue[core].append(hash);
        }

        // Remove and return the first authorization from the queue for a specific core
        pub fn popAuthorization(self: *@This(), core: usize) !?AuthorizerHash {
            if (core >= core_count) return error.InvalidCore;
            if (self.queue[core].items.len == 0) return null;
            return self.queue[core].orderedRemove(0);
        }

        // Get the number of authorizations in the queue for a specific core
        pub fn getQueueLength(self: *@This(), core: usize) !usize {
            if (core >= core_count) return error.InvalidCore;
            return self.queue[core].items.len;
        }
    };
}

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_ ___
// | | | | '_ \| | __|| |/ _ \/ __| __/ __|
// | |_| | | | | | |_ | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__||_|\___||___/\__|___/
//

const testing = std.testing;

pub const H: usize = 32; // Hash size

test "AuthorizationQueue - initialization and deinitialization" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    try testing.expectEqual(@as(usize, 2), auth_queue.queue.len);
    for (auth_queue.queue) |queue| {
        try testing.expectEqual(@as(usize, 0), queue.items.len);
    }
}

test "AuthorizationQueue - add and pop authorizations" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Add to core 0
    try auth_queue.addAuthorization(0, test_hash);
    try testing.expectEqual(@as(usize, 1), auth_queue.getQueueLength(0));

    // Pop from core 0
    const popped_hash = try auth_queue.popAuthorization(0);
    try testing.expect(popped_hash != null);
    try testing.expectEqualSlices(u8, &test_hash, &popped_hash.?);
    try testing.expectEqual(@as(usize, 0), auth_queue.getQueueLength(0));
}

test "AuthorizationQueue - queue full error" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Fill the queue
    for (0..6) |_| {
        try auth_queue.addAuthorization(0, test_hash);
    }

    // Try to add one more
    try testing.expectError(error.QueueFull, auth_queue.addAuthorization(0, test_hash));
}

test "AuthorizationQueue - invalid core error" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    try testing.expectError(error.InvalidCore, auth_queue.addAuthorization(2, test_hash));
    try testing.expect(auth_queue.popAuthorization(2) == error.InvalidCore);
    try testing.expectEqual(error.InvalidCore, auth_queue.getQueueLength(2));
}

test "AuthorizationQueue - multiple cores" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;

    try auth_queue.addAuthorization(0, test_hash1);
    try auth_queue.addAuthorization(1, test_hash2);

    try testing.expectEqual(@as(usize, 1), auth_queue.getQueueLength(0));
    try testing.expectEqual(@as(usize, 1), auth_queue.getQueueLength(1));

    const popped_hash1 = try auth_queue.popAuthorization(0);
    const popped_hash2 = try auth_queue.popAuthorization(1);

    try testing.expectEqualSlices(u8, &test_hash1, &popped_hash1.?);
    try testing.expectEqualSlices(u8, &test_hash2, &popped_hash2.?);
}

test "AuthorizationQueue - pop from empty queue" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    try testing.expect(try auth_queue.popAuthorization(0) == null);
}

test "AuthorizationQueue - FIFO order" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;
    const test_hash3 = [_]u8{3} ** H;

    try auth_queue.addAuthorization(0, test_hash1);
    try auth_queue.addAuthorization(0, test_hash2);
    try auth_queue.addAuthorization(0, test_hash3);

    try testing.expectEqualSlices(u8, &test_hash1, &(try auth_queue.popAuthorization(0)).?);
    try testing.expectEqualSlices(u8, &test_hash2, &(try auth_queue.popAuthorization(0)).?);
    try testing.expectEqualSlices(u8, &test_hash3, &(try auth_queue.popAuthorization(0)).?);
}
