const std = @import("std");
const types = @import("types.zig");

// Constants TODO: Move to configuration
const O: usize = 8; // Maximum number of items in the authorizations pool
const Q: usize = 80; // Maximum number of items in the authorizations queue

// Types
const Hash = [32]u8;
const AuthorizationPool = std.BoundedArray(Hash, O);
const AuthorizationQueue = std.BoundedArray(Hash, Q);

pub fn Alpha(comptime core_count: u16) type {
    return struct {
        //  α[c] The set of authorizers allowable for a particular core c as the
        //  authorizer pool TODO: this can become somewhat big, maybe better to allocate
        pools: [core_count]AuthorizationPool,

        pub fn init() @This() {
            var alpha = @This(){
                .pools = undefined,
            };
            for (0..core_count) |i| {
                alpha.pools[i] = AuthorizationPool.init(0) catch unreachable;
            }
            return alpha;
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/authorization.zig").jsonStringify(core_count, self, jw);
        }

        pub fn isAuthorized(self: *const @This(), core: usize, auth: Hash) bool {
            if (core >= core_count) return false;
            for (self.pools[core].constSlice()) |pool_auth| {
                if (std.mem.eql(u8, &pool_auth, &auth)) return true;
            }
            return false;
        }

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/authorization.zig").format(core_count, self, fmt, options, writer);
        }
    };
}
