const std = @import("std");

const AuthorizerHash = [32]u8;
pub fn Phi(
    comptime core_count: u16,
    comptime authorization_queue_length: u8,
) type {
    return struct {
        queue_data: [][32]u8,
        allocator: std.mem.Allocator,

        const total_slots = core_count * authorization_queue_length;

        pub fn init(allocator: std.mem.Allocator) !Phi(core_count, authorization_queue_length) {
            comptime {
                std.debug.assert(core_count > 0);
                std.debug.assert(authorization_queue_length > 0);
            }

            const queue_data = try allocator.alloc([32]u8, total_slots);
            errdefer allocator.free(queue_data);

            for (queue_data) |*slot| {
                slot.* = [_]u8{0} ** 32;
            }

            return .{ .queue_data = queue_data, .allocator = allocator };
        }

        pub fn deepClone(self: *const @This()) !@This() {
            std.debug.assert(self.queue_data.len == total_slots);

            const cloned_data = try self.allocator.alloc([32]u8, total_slots);
            errdefer self.allocator.free(cloned_data);

            @memcpy(cloned_data, self.queue_data);

            std.debug.assert(cloned_data.len == self.queue_data.len);

            return .{
                .queue_data = cloned_data,
                .allocator = self.allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.queue_data);
            self.* = undefined;
        }


        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const tfmt = @import("types/fmt.zig");
            const formatter = tfmt.Format(@TypeOf(self.*)){
                .value = self.*,
                .options = .{},
            };
            try formatter.format(fmt, options, writer);
        }

        pub fn getQueue(self: *const @This(), core: usize) ![][32]u8 {
            if (core >= core_count) return error.InvalidCore;

            const start_index = core * authorization_queue_length;
            const end_index = start_index + authorization_queue_length;
            return self.queue_data[start_index..end_index];
        }

        pub fn getAuthorization(self: *const @This(), core: usize, index: usize) AuthorizerHash {
            std.debug.assert(core < core_count);
            std.debug.assert(index < authorization_queue_length);

            const slot_index = core * authorization_queue_length + index;
            return self.queue_data[slot_index];
        }

        pub fn setAuthorization(self: *@This(), core: usize, index: usize, hash: AuthorizerHash) !void {
            if (core >= core_count) return error.InvalidCore;
            if (index >= authorization_queue_length) return error.InvalidIndex;

            const slot_index = core * authorization_queue_length + index;
            self.queue_data[slot_index] = hash;
        }

        pub fn clearAuthorization(self: *@This(), core: usize, index: usize) !void {
            if (core >= core_count) return error.InvalidCore;
            if (index >= authorization_queue_length) return error.InvalidIndex;

            const slot_index = core * authorization_queue_length + index;
            self.queue_data[slot_index] = [_]u8{0} ** 32;
        }

        pub fn isEmptySlot(self: *const @This(), core: usize, index: usize) bool {
            const hash = self.getAuthorization(core, index);
            for (hash) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        pub fn getQueueLength(self: *const @This(), core: usize) usize {
            _ = self;
            std.debug.assert(core < core_count);
            return authorization_queue_length;
        }
    };
}


const testing = std.testing;

pub const H: usize = 32; // Hash size

test "AuthorizationQueue - initialization and deinitialization" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

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

    try auth_queue.setAuthorization(0, 0, test_hash);
    try testing.expect(!auth_queue.isEmptySlot(0, 0));

    const retrieved_hash = auth_queue.getAuthorization(0, 0);
    try testing.expectEqualSlices(u8, &test_hash, &retrieved_hash);

    try testing.expectEqual(@as(usize, 6), auth_queue.getQueueLength(0));
}

test "AuthorizationQueue - invalid index error" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    try testing.expectError(error.InvalidIndex, auth_queue.setAuthorization(0, 6, test_hash));

    try testing.expectError(error.InvalidIndex, auth_queue.clearAuthorization(0, 6));
}

test "AuthorizationQueue - invalid core error" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash = [_]u8{1} ** H;

    try testing.expectError(error.InvalidCore, auth_queue.setAuthorization(2, 0, test_hash));
    try testing.expectError(error.InvalidCore, auth_queue.clearAuthorization(2, 0));
}

test "AuthorizationQueue - multiple cores" {
    var auth_queue = try Phi(2, 6).init(testing.allocator);
    defer auth_queue.deinit();

    const test_hash1 = [_]u8{1} ** H;
    const test_hash2 = [_]u8{2} ** H;

    try auth_queue.setAuthorization(0, 0, test_hash1);
    try auth_queue.setAuthorization(1, 2, test_hash2);

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

    try testing.expectEqualSlices(u8, &test_hash1, &cloned.getAuthorization(0, 0));
    try testing.expectEqualSlices(u8, &test_hash2, &cloned.getAuthorization(0, 1));
    try testing.expectEqualSlices(u8, &test_hash3, &cloned.getAuthorization(1, 3));

    try testing.expect(cloned.isEmptySlot(0, 2));
    try testing.expect(cloned.isEmptySlot(1, 0));
}
