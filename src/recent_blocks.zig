// TODO: rename this file to recent_history.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const merkle = @import("merkle_binary.zig");
const mmr = @import("merkle_mountain_ranges.zig");

pub const Hash = [32]u8;

pub const BlockInfo = struct {
    /// The hash of the block header
    header_hash: Hash,
    /// The root hash of the state trie
    state_root: Hash,
    /// The Merkle Mountain Range (MMR) of BEEFY commitments
    beefy_mmr: []?Hash,
    /// The hashes of work reports included in this block
    work_reports: []Hash,
};

/// Represents a recent block with information needed for importing
pub const RecentBlock = struct {
    /// The hash of the block header
    header_hash: Hash,
    /// The state root of the parent block (H_r)
    parent_state_root: Hash,
    /// The root of the accumulate result tree, derived from C using basic merklization (M_b)
    accumulate_root: Hash,
    /// The hashes of the work reports included in this block
    work_reports: []Hash,
};

/// Manages the recent history of blocks
pub const RecentHistory = struct {
    const Self = @This();

    allocator: Allocator,
    /// The list of recent blocks
    blocks: std.ArrayList(BlockInfo),
    /// The maximum number of blocks to keep in recent history
    max_blocks: usize,

    /// Initializes a new RecentHistory with the given allocator and maximum number of blocks
    pub fn init(allocator: Allocator, max_blocks: usize) !Self {
        return Self{
            .allocator = allocator,
            .blocks = try std.ArrayList(BlockInfo).initCapacity(allocator, max_blocks),
            .max_blocks = max_blocks,
        };
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try @import("state_json/recent_blocks.zig").jsonStringify(self, jw);
    }

    /// Frees all resources associated with the RecentHistory
    pub fn deinit(self: *Self) void {
        for (self.blocks.items) |*block| {
            self.allocator.free(block.beefy_mmr);
            self.allocator.free(block.work_reports);
        }
        self.blocks.deinit();
    }

    /// Imports a new block into the recent history
    pub fn import(self: *Self, allocator: Allocator, input: RecentBlock) !void {
        // Create a new BlockStateInformation
        var block_info = BlockInfo{
            .header_hash = input.header_hash,
            .state_root = std.mem.zeroes(Hash), // This will be updated in the next block
            .beefy_mmr = undefined,
            .work_reports = try allocator.dupe(Hash, input.work_reports),
        };

        // Update the parent block's state root if it exists
        if (self.blocks.items.len > 0) {
            self.blocks.items[self.blocks.items.len - 1].state_root = input.parent_state_root;
        }

        // Append the accumlate root Beefy MMR
        const last_beefy_mmr = if (self.blocks.getLastOrNull()) |last_block|
            try allocator.dupe(?Hash, last_block.beefy_mmr)
        else
            &[_]?Hash{};

        var beefy_mmr = mmr.MMR.fromOwnedSlice(allocator, @constCast(last_beefy_mmr));
        // errdefer beefy_mmr.deinit();

        // Append the accumulate root to the Beefy MMR
        try mmr.append(&beefy_mmr, input.accumulate_root, Keccak256);

        // Update the new block's Beefy MMR
        block_info.beefy_mmr = try beefy_mmr.toOwnedSlice();

        // Add the new block to the recent history
        try self.addBlockInfo(block_info);
    }

    /// Adds a new BlockInfo to the recent history, removing the oldest if at capacity
    pub fn addBlockInfo(self: *Self, new_block: BlockInfo) !void {
        if (self.blocks.items.len == self.max_blocks) {
            const oldest_block = self.blocks.orderedRemove(0);
            self.allocator.free(oldest_block.beefy_mmr);
            self.allocator.free(oldest_block.work_reports);
        }

        try self.blocks.append(new_block);
    }

    /// Retrieves the BlockInfo at the specified index, or null if not found
    pub fn getBlockInfo(self: Self, index: usize) ?BlockInfo {
        if (index < self.blocks.items.len) {
            return self.blocks.items[index];
        }
        return null;
    }
};

const testing = std.testing;

test RecentHistory {
    const allocator = testing.allocator;
    var recent_history = try RecentHistory.init(allocator, 3);
    defer recent_history.deinit();

    // Test initial state
    try testing.expectEqual(@as(usize, 0), recent_history.blocks.items.len);

    // Create some test blocks
    const block1 = BlockInfo{
        .header_hash = [_]u8{1} ** 32,
        .state_root = [_]u8{2} ** 32,
        .beefy_mmr = try allocator.dupe(?Hash, &.{[_]u8{3} ** 32}),
        .work_reports = try allocator.dupe(Hash, &.{[_]u8{4} ** 32}),
    };
    const block2 = BlockInfo{
        .header_hash = [_]u8{5} ** 32,
        .state_root = [_]u8{6} ** 32,
        .beefy_mmr = try allocator.dupe(?Hash, &.{[_]u8{7} ** 32}),
        .work_reports = try allocator.dupe(Hash, &.{[_]u8{8} ** 32}),
    };
    const block3 = BlockInfo{
        .header_hash = [_]u8{9} ** 32,
        .state_root = [_]u8{10} ** 32,
        .beefy_mmr = try allocator.dupe(?Hash, &.{[_]u8{11} ** 32}),
        .work_reports = try allocator.dupe(Hash, &.{[_]u8{12} ** 32}),
    };
    const block4 = BlockInfo{
        .header_hash = [_]u8{13} ** 32,
        .state_root = [_]u8{14} ** 32,
        .beefy_mmr = try allocator.dupe(?Hash, &.{[_]u8{15} ** 32}),
        .work_reports = try allocator.dupe(Hash, &.{[_]u8{16} ** 32}),
    };

    // Test adding blocks
    try recent_history.addBlockInfo(block1);
    try testing.expectEqual(@as(usize, 1), recent_history.blocks.items.len);

    try recent_history.addBlockInfo(block2);
    try testing.expectEqual(@as(usize, 2), recent_history.blocks.items.len);

    try recent_history.addBlockInfo(block3);
    try testing.expectEqual(@as(usize, 3), recent_history.blocks.items.len);

    // Test max_blocks limit
    try recent_history.addBlockInfo(block4);
    try testing.expectEqual(@as(usize, 3), recent_history.blocks.items.len);

    // Test get stateinformation
    const retrieved_block = recent_history.getBlockInfo(1);
    try testing.expect(retrieved_block != null);
    if (retrieved_block) |state_info| {
        try testing.expectEqualSlices(u8, &block3.header_hash, &state_info.header_hash);
    }

    // Test getting non-existent block
    const non_existent_block = recent_history.getBlockInfo(3);
    try testing.expect(non_existent_block == null);
}
