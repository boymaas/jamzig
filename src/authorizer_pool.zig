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
            // Compile-time assertions
            comptime {
                std.debug.assert(core_count > 0);
                std.debug.assert(max_pool_items > 0);
            }

            var alpha = @This(){
                .pools = undefined,
            };
            for (0..core_count) |i| {
                alpha.pools[i] = AuthorizationPool(max_pool_items).init(0) catch unreachable;
                // Postcondition: pool is initialized empty
                std.debug.assert(alpha.pools[i].len == 0);
            }

            // Postcondition: all pools initialized
            std.debug.assert(alpha.pools.len == core_count);
            return alpha;
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/authorization.zig").jsonStringify(core_count, max_pool_items, self, jw);
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

            // Add new auth if pool isn't full
            try pool.append(auth);

            // Postcondition: pool length increased by 1
            std.debug.assert(pool.len == initial_len + 1);
        }

        pub fn removeAuthorizer(self: *@This(), core: usize, auth: Hash) void {
            if (core >= core_count) return;

            var pool = &self.pools[core];
            const initial_len = pool.len;
            const slice = pool.slice();

            // Find and remove the matching auth hash
            for (slice, 0..) |pool_auth, i| {
                if (std.mem.eql(u8, &pool_auth, &auth)) {
                    _ = pool.orderedRemove(i);
                    // Postcondition: pool length decreased by 1
                    std.debug.assert(pool.len == initial_len - 1);
                    return;
                }
            }

            // Postcondition: if we reach here, auth was not found
            std.debug.assert(pool.len == initial_len);
        }

        pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
            _ = allocator; // Not used in this implementation since pools are stack-allocated

            // Preconditions
            std.debug.assert(self.pools.len == core_count);

            var clone = @This(){
                .pools = undefined,
            };

            // Clone each pool - caller must handle any needed allocations
            for (0..core_count) |i| {
                clone.pools[i] = try AuthorizationPool(max_pool_items).init(0);
                // Copy all hashes from the original pool
                const source_slice = self.pools[i].constSlice();
                for (source_slice) |hash| {
                    try clone.pools[i].append(hash);
                }

                // Postcondition: clone pool has same size as original
                std.debug.assert(clone.pools[i].len == self.pools[i].len);
            }

            // Postcondition: clone has same structure as original
            std.debug.assert(clone.pools.len == self.pools.len);
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
            // No dynamic allocations to free since pools are stack-allocated
            self.* = undefined;
        }
    };
}
