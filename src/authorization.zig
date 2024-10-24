const std = @import("std");
const types = @import("types.zig");

// Constants
pub const C: usize = 341; // Number of cores
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

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("pools");
        try jw.beginArray();
        for (self.pools) |pool| {
            try jw.beginArray();
            for (pool.constSlice()) |auth| {
                try jw.write(std.fmt.fmtSliceHexLower(&auth));
            }
            try jw.endArray();
        }
        try jw.endArray();

        try jw.objectField("queues");
        try jw.beginArray();
        for (self.queues) |queue| {
            try jw.beginArray();
            for (queue.constSlice()) |auth| {
                try jw.write(std.fmt.fmtSliceHexLower(&auth));
            }
            try jw.endArray();
        }
        try jw.endArray();

        try jw.endObject();
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
    pub fn transitionState(self: *Alpha, E_g: types.GuaranteesExtrinsic, H_t: types.TimeSlot) !void {
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

const testing = std.testing;

test "Alpha initialization" {
    const alpha = Alpha.init();
    try testing.expectEqual(@as(usize, 341), alpha.pools.len);
    try testing.expectEqual(@as(usize, 341), alpha.queues.len);

    for (alpha.pools) |pool| {
        try testing.expectEqual(@as(usize, 0), pool.len);
    }
    for (alpha.queues) |queue| {
        try testing.expectEqual(@as(usize, 0), queue.len);
    }
}

test "Alpha addToQueue and isAuthorized" {
    var alpha = Alpha.init();
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
    var alpha = Alpha.init();
    const core: usize = 0;
    const auth1: [32]u8 = [_]u8{1} ** 32;
    const auth2: [32]u8 = [_]u8{2} ** 32;

    try alpha.addToQueue(core, auth1);
    try alpha.addToQueue(core, auth2);

    var guarantees = [_]types.ReportGuarantee{.{
        .report = .{
            .package_spec = .{
                .hash = [_]u8{0} ** 32,
                .len = 0,
                .root = [_]u8{0} ** 32,
                .segments = [_]u8{0} ** 32,
            },
            .context = .{
                .anchor = [_]u8{0} ** 32,
                .state_root = [_]u8{0} ** 32,
                .beefy_root = [_]u8{0} ** 32,
                .lookup_anchor = [_]u8{0} ** 32,
                .lookup_anchor_slot = 0,
                .prerequisite = null,
            },
            .core_index = core,
            .authorizer_hash = auth1,
            .auth_output = &[_]u8{},
            .results = &[_]types.WorkResult{},
        },
        .slot = 0,
        .signatures = &[_]types.ValidatorSignature{},
    }};

    try alpha.transitionState(&guarantees, 0);

    try testing.expectEqual(1, alpha.pools[core].len);
    try testing.expectEqual(2, alpha.queues[core].len);
    try testing.expect(alpha.isAuthorized(core, auth1));
    try testing.expect(!alpha.isAuthorized(core, auth2));
}
