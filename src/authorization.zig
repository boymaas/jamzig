const std = @import("std");

const types = @import("types.zig");

// Constants
const C: usize = 341; // Number of cores
const O: usize = 8; // Maximum number of items in the authorizations pool
const Q: usize = 80; // Maximum number of items in the authorizations queue

// Types
const Hash = [32]u8;
const AuthorizationPool = std.BoundedArray(Hash, O);
const AuthorizationQueue = std.BoundedArray(Hash, Q);

pub const Alpha = struct {
    //  α[c] The set of authorizers allowable for a particular core c as the
    //  authorizer pool
    pools: [C]AuthorizationPool,
    // φ[c] may be altered only through an exogenous call made from the
    // accumulate logic of an appropriately privileged service
    queues: [C]AuthorizationQueue,

    pub fn init() Alpha {
        var alpha = Alpha{
            .pools = undefined,
            .queues = undefined,
        };
        for (0..C) |i| {
            alpha.pools[i] = AuthorizationPool.init(0) catch unreachable;
            alpha.queues[i] = AuthorizationQueue.init(0) catch unreachable;
        }
        return alpha;
    }

    // The state transition of a block involves placing a new authorization
    // into the pool from the queue
    //
    // Since α′ is dependent on φ′, practically speaking, this
    // step must be computed after accumulation, the stage in
    // which φ′ is defined.

    // NOTE: that we utilize the guarantees extrinsic EG to remove the oldest
    // authorizer which has been used to justify a guaranteed work-package in the
    // current block. This is further defined in equation (137)
    pub fn transitionState(self: *Alpha, E_g: []const types.GuaranteesExtrinsic, H_t: types.TimeSlot) !void {
        // Remove used authorizers from the pool
        for (E_g) |guarantee| {
            const core = guarantee.report.core_index;
            const auth_hash = guarantee.report.authorizer_hash;

            // Remove the authorizer from the pool if exists
            for (self.pools[core].slice(), 0..) |*pool_auth, i| {
                if (std.mem.eql(u8, pool_auth, &auth_hash)) {
                    _ = self.pools[core].orderedRemove(i);
                    break;
                }
            }

            // Add new authorizer from queue to pool if there's space
            if (self.pools[core].len < O and self.queues[core].len > 0) {
                const new_auth = self.queues[core].get(H_t % self.queues[core].len);
                self.pools[core].append(new_auth) catch |err| {
                    if (err == error.Overflow) {
                        // Ignore overflow error, as we don't want to grow beyond capacity
                        continue;
                    } else {
                        // For any other error, return it
                        return err;
                    }
                };
            }
        }
    }

    pub fn addToQueue(self: *Alpha, core: usize, auth: Hash) !void {
        if (core >= C) return error.InvalidCore;
        try self.queues[core].append(auth);
    }

    pub fn isAuthorized(self: *const Alpha, core: usize, auth: Hash) bool {
        if (core >= C) return false;
        for (self.pools[core].constSlice()) |pool_auth| {
            if (std.mem.eql(u8, &pool_auth, &auth)) return true;
        }
        return false;
    }

    pub fn debugPrint(self: *const Alpha, writer: anytype) !void {
        try writer.print("Alpha State:\n", .{});
        for (0..C) |c| {
            try writer.print("Core {d}:\n", .{c});
            try writer.print("  Pool: ", .{});
            for (self.pools[c].constSlice()) |auth| {
                try writer.print("{x} ", .{std.fmt.fmtSliceHexLower(&auth)});
            }
            try writer.print("\n  Queue: ", .{});
            for (self.queues[c].constSlice()) |auth| {
                try writer.print("{x} ", .{std.fmt.fmtSliceHexLower(&auth)});
            }
            try writer.print("\n", .{});
        }
    }

    pub fn format(
        self: Alpha,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Alpha{{ pools: {d} pools, queues: {d} queues }}", .{
            self.pools.len,
            self.queues.len,
        });
    }
};
