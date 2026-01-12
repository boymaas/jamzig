// NOTE: borrowed impl, will be replaced

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        pub const Size = u32;

        const bounds: Size = @intCast(capacity);

        pub const Timeout = union(enum) {
            instant: void,
            forever: void,
            ns: u64,
        };

        data: [bounds]T = undefined,

        write: Size = 0,
        read: Size = 0,
        len: Size = 0,

        mutex: std.Thread.Mutex = .{},

        cond_not_full: std.Thread.Condition = .{},
        not_full_waiters: usize = 0,

        pub fn create(alloc: Allocator) !*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .{},
                .cond_not_full = .{},
                .not_full_waiters = 0,
            };

            return ptr;
        }

        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        pub fn push(self: *Self, value: T, timeout: Timeout) Size {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.full()) {
                switch (timeout) {
                    .instant => return 0,
                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.wait(&self.mutex);
                    },
                    .ns => |ns| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.timedWait(&self.mutex, ns) catch return 0;
                    },
                }

                if (self.full()) return 0;
            }

            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        pub fn pushInstantNotFull(self: *Self, value: T) !void {
            if (self.push(value, .instant) == 0) {
                return error.QueueFull;
            }
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0) return null;

            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            if (self.not_full_waiters > 0) self.cond_not_full.signal();

            return self.data[n];
        }

        pub fn blockingPop(self: *Self) T {
            const sleep_interval_ns: u64 = 10 * std.time.ns_per_ms;
            while (true) {
                if (self.pop()) |value| {
                    return value;
                }
                std.time.sleep(sleep_interval_ns);
            }
        }

        pub fn timedBlockingPop(self: *Self, timeout_ms: u64) ?T {
            const start_time = std.time.nanoTimestamp();
            const timeout_ns = timeout_ms * std.time.ns_per_ms;
            const sleep_interval_ns: u64 = 10 * std.time.ns_per_ms;

            while (true) {
                if (self.pop()) |value| {
                    return value;
                }

                const current_time = std.time.nanoTimestamp();
                const elapsed_ns = current_time - start_time;
                if (elapsed_ns >= timeout_ns) {
                    return null;
                }

                const remaining_ns = timeout_ns - elapsed_ns;
                const actual_sleep_ns = @max(1, @min(sleep_interval_ns, remaining_ns));

                std.time.sleep(@intCast(actual_sleep_ns));
            }
        }

        pub fn drain(self: *Self) DrainIterator {
            self.mutex.lock();
            return .{ .queue = self };
        }

        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;

                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;

                return self.queue.data[n];
            }

            pub fn deinit(self: *DrainIterator) void {
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal();

                self.queue.mutex.unlock();
            }
        };

        inline fn full(self: *Self) bool {
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    try testing.expect(q.pop() == null);

    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(5, .{ .instant = {} }));

    try testing.expect(q.pop().? == 1);
    try testing.expect(q.pop().? == 2);
    try testing.expect(q.pop().? == 3);
    try testing.expect(q.pop().? == 4);
    try testing.expect(q.pop() == null);

    var it = q.drain();
    try testing.expect(it.next() == null);
    it.deinit();

    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(2, .{ .instant = {} }));

    try testing.expectEqual(@as(Q.Size, 0), q.push(2, .{ .ns = 1000 }));
}
