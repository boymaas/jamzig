///
/// Authorization Queue (φ) Implementation
///
/// This module implements the Authorization Queue (φ) as specified in the Jam protocol.
/// φ is a critical component of the state, maintaining pending authorizations for each core.
///
/// Key features:
/// - Maintains C separate queues, one for each core.
/// - Each queue has exactly Q authorization slots.
/// - Authorizations are 32-byte hashes.
/// - Supports setting/getting authorizations at specific indices.
///
const std = @import("std");

const AuthorizerHash = [32]u8;

// TODO: Authorization to Authorizer
// Define the AuthorizationQueue type
pub fn Phi(
    comptime core_count: u16,
    comptime authorization_queue_length: u8, // Q
) type {
    return struct {
        // Single contiguous heap allocation for all authorization slots
        queue_data: [][32]u8,
        allocator: std.mem.Allocator,

        const total_slots = core_count * authorization_queue_length;

        // Initialize the AuthorizationQueue
        pub fn init(allocator: std.mem.Allocator) !Phi(core_count, authorization_queue_length) {
            // Compile-time assertions
            comptime {
                std.debug.assert(core_count > 0);
                std.debug.assert(authorization_queue_length > 0);
            }

            // Allocate all slots in one contiguous block
            const queue_data = try allocator.alloc([32]u8, total_slots);
            errdefer allocator.free(queue_data);

            // Initialize all slots to zero
            for (queue_data) |*slot| {
                slot.* = [_]u8{0} ** 32;
            }

            return .{ .queue_data = queue_data, .allocator = allocator };
        }

        // Create a deep copy of the AuthorizationQueue
        pub fn deepClone(self: *const @This()) !@This() {
            // Preconditions
            std.debug.assert(self.queue_data.len == total_slots);

            // Allocate new queue data
            const cloned_data = try self.allocator.alloc([32]u8, total_slots);
            errdefer self.allocator.free(cloned_data);

            // Copy all slots
            @memcpy(cloned_data, self.queue_data);

            // Postcondition: clone has same data
            std.debug.assert(cloned_data.len == self.queue_data.len);

            return .{
                .queue_data = cloned_data,
                .allocator = self.allocator,
            };
        }

        // Deinitialize the AuthorizationQueue
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.queue_data);
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
                authorization_queue_length,
                self,
                fmt,
                options,
                writer,
            );
        }

        // Get the entire queue for a specific core
        pub fn getQueue(self: *const @This(), core: usize) ![][32]u8 {
            // Preconditions
            if (core >= core_count) return error.InvalidCore;

            const start_index = core * authorization_queue_length;
            const end_index = start_index + authorization_queue_length;
            return self.queue_data[start_index..end_index];
        }

        // Get an authorization at a specific index for a core
        pub fn getAuthorization(self: *const @This(), core: usize, index: usize) AuthorizerHash {
            // Preconditions
            // REFACTOR: do the same as in setAuthorization, where this function cal fail with error.InvalidCore or error.InvalidIndex
            std.debug.assert(core < core_count);
            std.debug.assert(index < authorization_queue_length);

            const slot_index = core * authorization_queue_length + index;
            return self.queue_data[slot_index];
        }

        // Set an authorization at a specific index for a core
        pub fn setAuthorization(self: *@This(), core: usize, index: usize, hash: AuthorizerHash) !void {
            if (core >= core_count) return error.InvalidCore;
            if (index >= authorization_queue_length) return error.InvalidIndex;

            const slot_index = core * authorization_queue_length + index;
            self.queue_data[slot_index] = hash;
        }

        // Clear an authorization at a specific index (set to zeros)
        pub fn clearAuthorization(self: *@This(), core: usize, index: usize) !void {
            if (core >= core_count) return error.InvalidCore;
            if (index >= authorization_queue_length) return error.InvalidIndex;

            const slot_index = core * authorization_queue_length + index;
            self.queue_data[slot_index] = [_]u8{0} ** 32;
        }

        // Check if an authorization slot is empty (all zeros)
        pub fn isEmptySlot(self: *const @This(), core: usize, index: usize) bool {
            const hash = self.getAuthorization(core, index);
            for (hash) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        // Get the fixed queue length (always returns Q)
        pub fn getQueueLength(self: *const @This(), core: usize) usize {
            _ = self;
            // Assertion instead of error for bounds check
            std.debug.assert(core < core_count);
            return authorization_queue_length;
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

    // Check all slots are initialized to zero
    for (0..2) |core| {
        for (0..6) |index| {
            try testing.expect(auth_queue.isEmptySlot(core, index));
        }
    }
}

test "AuthorizationQueue - set and get authorizations" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Set at core 0, index 0
    try auth_queue.setAuthorization(0, 0, test_hash);
    try testing.expect(!auth_queue.isEmptySlot(0, 0));

    // Get from core 0, index 0
    const retrieved_hash = auth_queue.getAuthorization(0, 0);
    try testing.expectEqualSlices(u8, &test_hash, &retrieved_hash);

    // Queue length is always fixed
    try testing.expectEqual(@as(usize, 6), auth_queue.getQueueLength(0));
}

test "AuthorizationQueue - invalid index error" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Try to set at invalid index
    try testing.expectError(error.InvalidIndex, auth_queue.setAuthorization(0, 6, test_hash));

    // Clear at invalid index should also error
    try testing.expectError(error.InvalidIndex, auth_queue.clearAuthorization(0, 6));
}

test "AuthorizationQueue - invalid core error" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    try testing.expectError(error.InvalidCore, auth_queue.setAuthorization(2, 0, test_hash));
    try testing.expectError(error.InvalidCore, auth_queue.clearAuthorization(2, 0));
    // getAuthorization and getQueueLength use assertions instead of returning errors
    // Attempting to access invalid core would trigger assertion failure in debug mode
}

test "AuthorizationQueue - multiple cores" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;

    try auth_queue.setAuthorization(0, 0, test_hash1);
    try auth_queue.setAuthorization(1, 2, test_hash2);

    // Queue length is always fixed
    try testing.expectEqual(@as(usize, 6), auth_queue.getQueueLength(0));
    try testing.expectEqual(@as(usize, 6), auth_queue.getQueueLength(1));

    const retrieved_hash1 = auth_queue.getAuthorization(0, 0);
    const retrieved_hash2 = auth_queue.getAuthorization(1, 2);

    try testing.expectEqualSlices(u8, &test_hash1, &retrieved_hash1);
    try testing.expectEqualSlices(u8, &test_hash2, &retrieved_hash2);
}

test "AuthorizationQueue - clear authorization" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    // Set and then clear
    try auth_queue.setAuthorization(0, 3, test_hash);
    try testing.expect(!auth_queue.isEmptySlot(0, 3));

    try auth_queue.clearAuthorization(0, 3);
    try testing.expect(auth_queue.isEmptySlot(0, 3));
}

test "AuthorizationQueue - deep clone" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;
    const test_hash3 = [_]u8{3} ** H;

    try auth_queue.setAuthorization(0, 0, test_hash1);
    try auth_queue.setAuthorization(0, 1, test_hash2);
    try auth_queue.setAuthorization(1, 3, test_hash3);

    var cloned = try auth_queue.deepClone();
    defer cloned.deinit();

    // Verify cloned data matches
    try testing.expectEqualSlices(u8, &test_hash1, &cloned.getAuthorization(0, 0));
    try testing.expectEqualSlices(u8, &test_hash2, &cloned.getAuthorization(0, 1));
    try testing.expectEqualSlices(u8, &test_hash3, &cloned.getAuthorization(1, 3));

    // Verify empty slots are still empty
    try testing.expect(cloned.isEmptySlot(0, 2));
    try testing.expect(cloned.isEmptySlot(1, 0));
}
