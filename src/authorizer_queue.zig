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
            // Compile-time assertions
            comptime {
                std.debug.assert(core_count > 0);
                std.debug.assert(max_authorizations_queue_items > 0);
            }
            
            var queue: [core_count]std.ArrayList(AuthorizerHash) = undefined;
            for (0..core_count) |i| {
                queue[i] = std.ArrayList(AuthorizerHash).init(allocator);
                // Postcondition: queue is initialized empty
                std.debug.assert(queue[i].items.len == 0);
            }
            
            // Postcondition: all queues initialized
            std.debug.assert(queue.len == core_count);
            return .{ .queue = queue, .allocator = allocator };
        }

        // Create a deep copy of the AuthorizationQueue
        pub fn deepClone(self: *const @This()) !@This() {
            // Preconditions
            std.debug.assert(self.queue.len == core_count);
            
            // Initialize a new queue with the same allocator
            var cloned: @This() = .{
                .allocator = self.allocator,
                .queue = undefined,
            };

            // Deep copy each core's queue
            // TIGER STYLE: No hidden allocations - caller controls memory
            for (0..core_count) |i| {
                // Initialize new ArrayList for each core
                cloned.queue[i] = std.ArrayList(AuthorizerHash).init(self.allocator);
                // Reserve capacity to avoid multiple allocations
                try cloned.queue[i].ensureTotalCapacity(self.queue[i].items.len);
                // Copy items directly
                for (self.queue[i].items) |item| {
                    try cloned.queue[i].append(item);
                }
                
                // Postcondition: cloned queue has same length as original
                std.debug.assert(cloned.queue[i].items.len == self.queue[i].items.len);
            }
            
            // Postcondition: clone has same structure as original
            std.debug.assert(cloned.queue.len == self.queue.len);
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
            // Preconditions
            std.debug.assert(self.queue.len == core_count);
            std.debug.assert(hash.len == @sizeOf(AuthorizerHash));
            
            if (core >= core_count) return error.InvalidCore;
            if (self.queue[core].items.len >= max_authorizations_queue_items) return error.QueueFull;
            
            const initial_len = self.queue[core].items.len;
            try self.queue[core].append(hash);
            
            // Postcondition: queue length increased by 1
            std.debug.assert(self.queue[core].items.len == initial_len + 1);
        }

        // Remove and return the first authorization from the queue for a specific core
        pub fn popAuthorization(self: *@This(), core: usize) !?AuthorizerHash {
            // Preconditions
            std.debug.assert(self.queue.len == core_count);
            
            if (core >= core_count) return error.InvalidCore;
            if (self.queue[core].items.len == 0) return null;
            
            const initial_len = self.queue[core].items.len;
            const result = self.queue[core].orderedRemove(0);
            
            // Postcondition: queue length decreased by 1
            std.debug.assert(self.queue[core].items.len == initial_len - 1);
            return result;
        }

        // Get the number of authorizations in the queue for a specific core
        pub fn getQueueLength(self: *const @This(), core: usize) usize {
            // Assertion instead of error for bounds check
            std.debug.assert(core < core_count);
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
    // getQueueLength now uses assertions instead of returning errors
    // Attempting to access invalid core would trigger assertion failure in debug mode
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
