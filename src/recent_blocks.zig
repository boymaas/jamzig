const std = @import("std");
const Allocator = std.mem.Allocator;
const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);
const Keccak256 = std.crypto.hash.sha3.Keccak256;

const types = @import("types.zig");
const merkle = @import("merkle/binary.zig");
const mmr = @import("merkle/mmr.zig");

const jam_params = @import("jam_params.zig");

/// NOTE: this type was defined in the history test vectors, thus this is NOT
/// a domain type!
pub const RecentBlock = struct {
    header_hash: types.Hash,
    parent_state_root: types.Hash,
    accumulate_root: types.Hash,
    work_reports: []types.ReportedWorkPackage,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.work_reports);
    }

    pub fn fromBlock(comptime params: jam_params.Params, allocator: std.mem.Allocator, block: *const types.Block, accumulate_root: types.AccumulateRoot) !@This() {
        return RecentBlock{
            .header_hash = try block.header.header_hash(params, allocator),
            .parent_state_root = block.header.parent_state_root,
            .accumulate_root = accumulate_root,
            .work_reports = blk: {
                var reports = std.ArrayList(types.ReportedWorkPackage).init(allocator);
                errdefer reports.deinit();

                for (block.extrinsic.guarantees.data) |guarantee| {
                    try reports.append(.{
                        .hash = guarantee.report.package_spec.hash,
                        .exports_root = guarantee.report.package_spec.exports_root,
                    });
                }

                std.sort.insertion(types.ReportedWorkPackage, reports.items, {}, struct {
                    pub fn lessThan(_: void, a: types.ReportedWorkPackage, b: types.ReportedWorkPackage) bool {
                        return std.mem.lessThan(u8, &a.hash, &b.hash);
                    }
                }.lessThan);

                break :blk try reports.toOwnedSlice();
            },
        };
    }
};

/// Manages the recent history of blocks
pub const RecentHistory = struct {
    const Self = @This();

    allocator: Allocator,
    /// The list of recent blocks
    blocks: std.ArrayList(types.BlockInfo),
    /// The maximum number of blocks to keep in recent history
    max_blocks: usize,

    /// Initializes a new RecentHistory with the given allocator and maximum number of blocks
    pub fn init(allocator: Allocator, max_blocks: usize) !Self {
        return Self{
            .allocator = allocator,
            .blocks = try std.ArrayList(types.BlockInfo).initCapacity(allocator, max_blocks),
            .max_blocks = max_blocks,
        };
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

    pub fn deinit(self: *Self) void {
        for (self.blocks.items) |*block| {
            block.deinit(self.allocator);
        }
        self.blocks.deinit();
        self.* = undefined;
    }

    pub fn import(self: *Self, input: RecentBlock) !void {
        var block_info = types.BlockInfo{
            .header_hash = input.header_hash,
            .state_root = std.mem.zeroes(types.StateRoot),
            .beefy_mmr = undefined,
            .work_reports = input.work_reports,
        };

        if (self.blocks.items.len > 0) {
            self.blocks.items[self.blocks.items.len - 1].state_root = input.parent_state_root;
        }

        const last_beefy_mmr = if (self.blocks.getLastOrNull()) |last_block|
            try self.allocator.dupe(?types.Hash, last_block.beefy_mmr)
        else
            &[_]?types.Hash{};

        var beefy_mmr = mmr.MMR.fromOwnedSlice(self.allocator, @constCast(last_beefy_mmr));
        errdefer beefy_mmr.deinit();

        try mmr.append(&beefy_mmr, input.accumulate_root, Keccak256);

        block_info.beefy_mmr = try beefy_mmr.toOwnedSlice();

        try self.addBlockInfo(block_info);
    }

    pub fn addBlockInfo(self: *Self, new_block: types.BlockInfo) !void {
        if (self.blocks.items.len == self.max_blocks) {
            var oldest_block = self.blocks.orderedRemove(0);
            oldest_block.deinit(self.allocator);
        }

        try self.blocks.append(new_block);
    }

    pub fn getBlockInfo(self: Self, index: usize) ?types.BlockInfo {
        if (index < self.blocks.items.len) {
            return self.blocks.items[index];
        }
        return null;
    }

    pub fn getBlockInfoByHash(self: Self, header_hash: types.Hash) ?types.BlockInfo {
        for (self.blocks.items) |block| {
            if (std.mem.eql(u8, &block.header_hash, &header_hash)) {
                return block;
            }
        }
        return null;
    }

    pub fn updateParentBlockStateRoot(self: *Self, parent_state_root: types.Hash) void {
        if (self.blocks.items.len > 0) {
            self.blocks.items[self.blocks.items.len - 1].state_root = parent_state_root;
        }
    }

    pub fn getLastBlockHash(self: *const Self) types.Hash {
        if (self.blocks.getLastOrNull()) |last_block| {
            return last_block.header_hash;
        }
        return std.mem.zeroes(types.Hash);
    }

    pub fn deepClone(self: *const Self, allocator: Allocator) !Self {
        var clone = try Self.init(allocator, self.max_blocks);
        errdefer clone.deinit();

        for (self.blocks.items) |block| {
            const cloned_block = try block.deepClone(allocator);
            try clone.addBlockInfo(cloned_block);
        }
        return clone;
    }
};

const testing = std.testing;

test RecentHistory {
    const allocator = testing.allocator;
    var recent_history = try RecentHistory.init(allocator, 3);
    defer recent_history.deinit();

    try testing.expectEqual(@as(usize, 0), recent_history.blocks.items.len);

    const block1 = types.BlockInfo{
        .header_hash = [_]u8{1} ** 32,
        .state_root = [_]u8{2} ** 32,
        .beefy_mmr = try allocator.dupe(?types.Hash, &.{[_]u8{3} ** 32}),
        .work_reports = try allocator.dupe(types.ReportedWorkPackage, &.{.{
            .hash = [_]u8{4} ** 32,
            .exports_root = [_]u8{40} ** 32,
        }}),
    };
    const block2 = types.BlockInfo{
        .header_hash = [_]u8{5} ** 32,
        .state_root = [_]u8{6} ** 32,
        .beefy_mmr = try allocator.dupe(?types.Hash, &.{[_]u8{7} ** 32}),
        .work_reports = try allocator.dupe(types.ReportedWorkPackage, &.{.{
            .hash = [_]u8{8} ** 32,
            .exports_root = [_]u8{80} ** 32,
        }}),
    };
    const block3 = types.BlockInfo{
        .header_hash = [_]u8{9} ** 32,
        .state_root = [_]u8{10} ** 32,
        .beefy_mmr = try allocator.dupe(?types.Hash, &.{[_]u8{11} ** 32}),
        .work_reports = try allocator.dupe(types.ReportedWorkPackage, &.{.{
            .hash = [_]u8{12} ** 32,
            .exports_root = [_]u8{120} ** 32,
        }}),
    };
    const block4 = types.BlockInfo{
        .header_hash = [_]u8{13} ** 32,
        .state_root = [_]u8{14} ** 32,
        .beefy_mmr = try allocator.dupe(?types.Hash, &.{[_]u8{15} ** 32}),
        .work_reports = try allocator.dupe(types.ReportedWorkPackage, &.{.{
            .hash = [_]u8{16} ** 32,
            .exports_root = [_]u8{160} ** 32,
        }}),
    };

    try recent_history.addBlockInfo(block1);
    try testing.expectEqual(@as(usize, 1), recent_history.blocks.items.len);

    try recent_history.addBlockInfo(block2);
    try testing.expectEqual(@as(usize, 2), recent_history.blocks.items.len);

    try recent_history.addBlockInfo(block3);
    try testing.expectEqual(@as(usize, 3), recent_history.blocks.items.len);

    try recent_history.addBlockInfo(block4);
    try testing.expectEqual(@as(usize, 3), recent_history.blocks.items.len);

    const retrieved_block = recent_history.getBlockInfo(1);
    try testing.expect(retrieved_block != null);
    if (retrieved_block) |state_info| {
        try testing.expectEqualSlices(u8, &block3.header_hash, &state_info.header_hash);
    }

    const non_existent_block = recent_history.getBlockInfo(3);
    try testing.expect(non_existent_block == null);
}
