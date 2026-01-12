const std = @import("std");
const types = @import("types.zig");

const Hash = types.OpaqueHash;
pub fn AuthorizationPool(comptime max_pool_items: u8) type {
    return std.BoundedArray(Hash, max_pool_items);
}

pub fn Alpha(comptime core_count: u16, comptime max_pool_items: u8) type {
    return struct {
        pools: [core_count]AuthorizationPool(max_pool_items),

        pub fn init() @This() {
            comptime {
                std.debug.assert(core_count > 0);
                std.debug.assert(max_pool_items > 0);
            }

            var alpha = @This(){
                .pools = undefined,
            };
            for (0..core_count) |i| {
                alpha.pools[i] = AuthorizationPool(max_pool_items).init(0) catch unreachable;
                std.debug.assert(alpha.pools[i].len == 0);
            }

            std.debug.assert(alpha.pools.len == core_count);
            return alpha;
        }


        pub fn isAuthorized(self: *const @This(), core: usize, auth: Hash) bool {
            if (core >= core_count) return false;

            const pool_slice = self.pools[core].constSlice();
            for (pool_slice) |pool_auth| {
                if (std.mem.eql(u8, &pool_auth, &auth)) return true;
            }
            return false;
        }

        pub fn addAuthorizer(self: *@This(), core: usize, auth: Hash) !void {
            if (core >= core_count) return error.InvalidCore;

            var pool = &self.pools[core];
            const initial_len = pool.len;

            try pool.append(auth);

            std.debug.assert(pool.len == initial_len + 1);
        }

        pub fn removeAuthorizer(self: *@This(), core: usize, auth: Hash) void {
            if (core >= core_count) return;

            var pool = &self.pools[core];
            const initial_len = pool.len;
            const slice = pool.slice();

            for (slice, 0..) |pool_auth, i| {
                if (std.mem.eql(u8, &pool_auth, &auth)) {
                    _ = pool.orderedRemove(i);
                    std.debug.assert(pool.len == initial_len - 1);
                    return;
                }
            }

            std.debug.assert(pool.len == initial_len);
        }

        pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
            _ = allocator;

            std.debug.assert(self.pools.len == core_count);

            var clone = @This(){
                .pools = undefined,
            };

            for (0..core_count) |i| {
                clone.pools[i] = try AuthorizationPool(max_pool_items).init(0);
                const source_slice = self.pools[i].constSlice();
                for (source_slice) |hash| {
                    try clone.pools[i].append(hash);
                }

                std.debug.assert(clone.pools[i].len == self.pools[i].len);
            }

            std.debug.assert(clone.pools.len == self.pools.len);
            return clone;
        }

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const tfmt = @import("types/fmt.zig");
            const formatter = tfmt.Format(@TypeOf(self)){
                .value = self,
                .options = .{},
            };
            try formatter.format(fmt, options, writer);
        }

        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }
    };
}
