const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Hash = [32]u8;

pub const RecentBlock = struct {
    header_hash: Hash,
    state_root: Hash,
    beefy_mmr: []const Hash,
    work_report_hashes: []const Hash,
};

pub const RecentHistory = struct {
    const Self = @This();

    allocator: Allocator,
    blocks: std.ArrayList(RecentBlock),
    max_blocks: usize,

    pub fn init(allocator: Allocator, max_blocks: usize) !Self {
        return Self{
            .allocator = allocator,
            .blocks = try std.ArrayList(RecentBlock).initCapacity(allocator, max_blocks),
            .max_blocks = max_blocks,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.blocks.items) |*block| {
            self.allocator.free(block.beefy_mmr);
            self.allocator.free(block.work_report_hashes);
        }
        self.blocks.deinit();
    }

    pub fn addBlock(self: *Self, new_block: RecentBlock) !void {
        if (self.blocks.items.len == self.max_blocks) {
            const oldest_block = self.blocks.orderedRemove(0);
            self.allocator.free(oldest_block.beefy_mmr);
            self.allocator.free(oldest_block.work_report_hashes);
        }

        try self.blocks.append(new_block);
    }

    pub fn getBlock(self: Self, index: usize) ?RecentBlock {
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
    const block1 = RecentBlock{
        .header_hash = [_]u8{1} ** 32,
        .state_root = [_]u8{2} ** 32,
        .beefy_mmr = try allocator.dupe(Hash, &.{[_]u8{3} ** 32}),
        .work_report_hashes = try allocator.dupe(Hash, &.{[_]u8{4} ** 32}),
    };
    const block2 = RecentBlock{
        .header_hash = [_]u8{5} ** 32,
        .state_root = [_]u8{6} ** 32,
        .beefy_mmr = try allocator.dupe(Hash, &.{[_]u8{7} ** 32}),
        .work_report_hashes = try allocator.dupe(Hash, &.{[_]u8{8} ** 32}),
    };
    const block3 = RecentBlock{
        .header_hash = [_]u8{9} ** 32,
        .state_root = [_]u8{10} ** 32,
        .beefy_mmr = try allocator.dupe(Hash, &.{[_]u8{11} ** 32}),
        .work_report_hashes = try allocator.dupe(Hash, &.{[_]u8{12} ** 32}),
    };
    const block4 = RecentBlock{
        .header_hash = [_]u8{13} ** 32,
        .state_root = [_]u8{14} ** 32,
        .beefy_mmr = try allocator.dupe(Hash, &.{[_]u8{15} ** 32}),
        .work_report_hashes = try allocator.dupe(Hash, &.{[_]u8{16} ** 32}),
    };

    // Test adding blocks
    try recent_history.addBlock(block1);
    try testing.expectEqual(@as(usize, 1), recent_history.blocks.items.len);

    try recent_history.addBlock(block2);
    try testing.expectEqual(@as(usize, 2), recent_history.blocks.items.len);

    try recent_history.addBlock(block3);
    try testing.expectEqual(@as(usize, 3), recent_history.blocks.items.len);

    // Test max_blocks limit
    try recent_history.addBlock(block4);
    try testing.expectEqual(@as(usize, 3), recent_history.blocks.items.len);

    // Test getBlock
    const retrieved_block = recent_history.getBlock(1);
    try testing.expect(retrieved_block != null);
    if (retrieved_block) |block| {
        try testing.expectEqualSlices(u8, &block3.header_hash, &block.header_hash);
    }

    // Test getting non-existent block
    const non_existent_block = recent_history.getBlock(3);
    try testing.expect(non_existent_block == null);
}
