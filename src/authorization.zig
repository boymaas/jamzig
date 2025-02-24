const std = @import("std");
const types = @import("types.zig");

// Types
const Hash = types.OpaqueHash;
pub fn AuthorizationPool(comptime max_pool_items: u8) type {
    return std.BoundedArray(Hash, max_pool_items);
}

pub fn Alpha(comptime core_count: u16, comptime max_pool_items: u8) type {
    return struct {
        //  α[c] The set of authorizers allowable for a particular core c as the
        //  authorizer pool
        pools: [core_count]AuthorizationPool(max_pool_items),

        pub fn init() @This() {
            var alpha = @This(){
                .pools = undefined,
            };
            for (0..core_count) |i| {
                alpha.pools[i] = AuthorizationPool(max_pool_items).init(0) catch unreachable;
            }
            return alpha;
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/authorization.zig").jsonStringify(core_count, max_pool_items, self, jw);
        }

        pub fn isAuthorized(self: *const @This(), core: usize, auth: Hash) bool {
            if (core >= core_count) return false;
            for (self.pools[core].constSlice()) |pool_auth| {
                if (std.mem.eql(u8, &pool_auth, &auth)) return true;
            }
            return false;
        }

        pub fn addAuthorizer(self: *@This(), core: usize, auth: Hash) !void {
            if (core >= core_count) return error.InvalidCore;

            var pool = &self.pools[core];

            // Add new auth if pool isn't full
            try pool.append(auth);
        }

        pub fn removeAuthorizer(self: *@This(), core: usize, auth: Hash) void {
            if (core >= core_count) return;

            var pool = &self.pools[core];
            const slice = pool.slice();

            // Find and remove the matching auth hash
            for (slice, 0..) |pool_auth, i| {
                if (std.mem.eql(u8, &pool_auth, &auth)) {
                    _ = pool.orderedRemove(i);
                    return;
                }
            }
        }

        pub fn deepClone(self: *const @This()) !@This() {
            var clone = @This(){
                .pools = undefined,
            };

            // Clone each pool
            for (0..core_count) |i| {
                clone.pools[i] = try AuthorizationPool(max_pool_items).init(0);
                // Copy all hashes from the original pool
                try clone.pools[i].appendSlice(self.pools[i].constSlice());
            }

            return clone;
        }

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/authorization.zig").format(core_count, max_pool_items, self, fmt, options, writer);
        }

        pub fn deinit(self: *@This()) void {
            // No need to deallocate self since it was stack-allocated
            self.* = undefined;
        }
    };
}
