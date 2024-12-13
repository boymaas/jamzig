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
        // φ[c] may be altered only through an exogenous call made from the
        // accumulate logic of an appropriately privileged service
        queues: [core_count]AuthorizationQueue, // FIX: remove its now in seperate file

        pub fn init() @This() {
            var alpha = @This(){
                .pools = undefined,
                .queues = undefined,
            };
            for (0..core_count) |i| {
                alpha.pools[i] = AuthorizationPool.init(0) catch unreachable;
                alpha.queues[i] = AuthorizationQueue.init(0) catch unreachable;
            }
            return alpha;
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/authorization.zig").jsonStringify(core_count, self, jw);
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
        // FIX: place this on transisiton level, as it seems to use queue and core
        pub fn transitionState(self: *@This(), E_g: types.GuaranteesExtrinsic, H_t: types.TimeSlot) !void {
            // Remove used authorizers from the pool
            for (E_g.data) |guarantee| {
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

        pub fn addToQueue(self: *@This(), core: usize, auth: Hash) !void {
            if (core >= core_count) return error.InvalidCore;
            try self.queues[core].append(auth);
        }

        pub fn isAuthorized(self: *const @This(), core: usize, auth: Hash) bool {
            if (core >= core_count) return false;
            for (self.pools[core].constSlice()) |pool_auth| {
                if (std.mem.eql(u8, &pool_auth, &auth)) return true;
            }
            return false;
        }

        pub fn debugPrint(self: *const @This(), writer: anytype) !void {
            try writer.print(@typeName(@This()) ++ "State:\n", .{});
            for (0..core_count) |c| {
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
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print(@typeName(@This()) ++ "{{ pools: {d} pools, queues: {d} queues }}", .{
                self.pools.len,
                self.queues.len,
            });
        }
    };
}

const testing = std.testing;

test "Alpha initialization" {
    const core_count: u16 = 341;
    const alpha = Alpha(core_count).init();
    try testing.expectEqual(@as(usize, core_count), alpha.pools.len);
    try testing.expectEqual(@as(usize, core_count), alpha.queues.len);

    for (alpha.pools) |pool| {
        try testing.expectEqual(@as(usize, 0), pool.len);
    }
    for (alpha.queues) |queue| {
        try testing.expectEqual(@as(usize, 0), queue.len);
    }
}

test "Alpha addToQueue and isAuthorized" {
    const core_count: u16 = 341;
    var alpha = Alpha(core_count).init();
    const core: usize = 0;
    const auth: [32]u8 = [_]u8{1} ** 32;

    try alpha.addToQueue(core, auth);
    try testing.expectEqual(@as(usize, 1), alpha.queues[core].len);
    try testing.expect(!alpha.isAuthorized(core, auth));

    // Test invalid core
    try testing.expectError(error.InvalidCore, alpha.addToQueue(341, auth));
    try testing.expect(!alpha.isAuthorized(341, auth));
}

test "Alpha transitionState" {
    const core_count: u16 = 341;
    var alpha = Alpha(core_count).init();
    const core: usize = 0;
    const auth1: [32]u8 = [_]u8{1} ** 32;
    const auth2: [32]u8 = [_]u8{2} ** 32;

    try alpha.addToQueue(core, auth1);
    try alpha.addToQueue(core, auth2);

    var guarantees = [_]types.ReportGuarantee{.{
        .report = .{
            .package_spec = .{
                .hash = [_]u8{0} ** 32,
                .length = 0,
                .erasure_root = [_]u8{0} ** 32,
                .exports_root = [_]u8{0} ** 32,
                .exports_count = 0,
            },
            .context = .{
                .anchor = [_]u8{0} ** 32,
                .state_root = [_]u8{0} ** 32,
                .beefy_root = [_]u8{0} ** 32,
                .lookup_anchor = [_]u8{0} ** 32,
                .lookup_anchor_slot = 0,
                .prerequisites = &[_]types.OpaqueHash{},
            },
            .segment_root_lookup = &[_]types.SegmentRootLookupItem{},
            .core_index = core,
            .authorizer_hash = auth1,
            .auth_output = &[_]u8{},
            .results = &[_]types.WorkResult{},
        },
        .slot = 0,
        .signatures = &[_]types.ValidatorSignature{},
    }};

    try alpha.transitionState(.{ .data = &guarantees }, 0);

    try testing.expectEqual(1, alpha.pools[core].len);
    try testing.expectEqual(2, alpha.queues[core].len);
    try testing.expect(alpha.isAuthorized(core, auth1));
    try testing.expect(!alpha.isAuthorized(core, auth2));
}
