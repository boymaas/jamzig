const std = @import("std");
const meta = @import("../meta.zig");

pub fn CopyOnWrite(comptime T: type) type {
    return struct {
        source: *const T,
        mutable: ?T = null,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, source: *const T) Self {
            return Self{
                .source = source,
                .allocator = allocator,
            };
        }

        pub fn deepClone(self: *@This()) @This() {
            return Self{
                .source = self.source,
                .mutable = if (self.mutable) |m| blk: {
                    break :blk try meta.callDeepClone(m, self.allocator);
                } else null,
                .allocator = self.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.mutable) |m| {
                meta.callDeinit(m, self.allocator);
                self.mutable = null;
            }
            self.* = undefined;
        }

        pub fn getMutable(self: *Self) !*T {
            if (self.mutable == null) {
                self.mutable = try meta.callDeepClone(self.source, self.allocator);
            }
            return self.mutable.?;
        }

        pub fn getReadOnly(self: *Self) *const T {
            return if (self.mutable) |*m| m else self.source;
        }

        pub fn commit(self: *Self) !void {
            if (self.mutable) |m| {
                const source = @constCast(self.source);
                meta.callDeinit(source, self.allocator);
                source.* = m;
                self.mutable = null;
            }
        }
    };
}
