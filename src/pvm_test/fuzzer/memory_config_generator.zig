const std = @import("std");
const Allocator = std.mem.Allocator;
const PVM = @import("../../pvm.zig").PVM;
const SeedGenerator = @import("seed.zig").SeedGenerator;

pub const MemoryConfigGenerator = struct {
    allocator: Allocator,
    seed_gen: *SeedGenerator,

    const Self = @This();

    const Range = struct { start: u32, end: u32 };

    pub fn init(allocator: Allocator, seed_gen: *SeedGenerator) Self {
        return .{
            .allocator = allocator,
            .seed_gen = seed_gen,
        };
    }

    /// Generate a random number of page configurations that cover all memory accesses
    pub fn generatePageConfigs(self: *Self, memory_accesses: []const u32) ![]PVM.PageMapConfig {
        var ranges = std.ArrayList(Range).init(self.allocator);
        defer ranges.deinit();

        // First, create ranges for all memory accesses
        // Each range will be page-aligned and cover a reasonable size around the access
        for (memory_accesses) |addr| {
            const page_size = self.seed_gen.randomIntRange(u32, 4096, 8192); // Random page size
            const page_aligned_addr = addr & ~@as(u32, 4095); // Align to 4K boundary
            try ranges.append(.{
                .start = page_aligned_addr,
                .end = page_aligned_addr + page_size,
            });
        }

        // Sort ranges by start address
        std.sort.insertion(Range, ranges.items, {}, rangeStartLessThan);

        // Merge overlapping ranges
        var merged = std.ArrayList(Range).init(self.allocator);
        defer merged.deinit();

        if (ranges.items.len > 0) {
            var current = ranges.items[0];
            for (ranges.items[1..]) |range| {
                if (range.start <= current.end) {
                    // Ranges overlap, extend current range
                    current.end = @max(current.end, range.end);
                } else {
                    // No overlap, append current and start new range
                    try merged.append(current);
                    current = range;
                }
            }
            try merged.append(current);
        }

        // Calculate how many additional random pages we can add
        const existing_pages = merged.items.len;
        const max_additional = @min(8, 8 - existing_pages);
        const additional_pages = if (max_additional > 0)
            self.seed_gen.randomIntRange(u8, 1, @intCast(max_additional))
        else
            0;

        // Allocate space for all configs
        const total_pages = existing_pages + additional_pages;
        const configs = try self.allocator.alloc(PVM.PageMapConfig, total_pages);
        errdefer self.allocator.free(configs);

        // First, create configs for all merged ranges
        for (merged.items, 0..existing_pages) |range, i| {
            configs[i] = .{
                .address = range.start,
                .length = range.end - range.start,
                .is_writable = self.generateRandomPermissions(),
            };
        }

        // Then add random configs
        var used_ranges = std.ArrayList(Range).init(self.allocator);
        defer used_ranges.deinit();
        try used_ranges.appendSlice(merged.items);

        for (existing_pages..total_pages) |i| {
            configs[i] = try self.generateSingleConfig(&used_ranges);
            try used_ranges.append(.{
                .start = configs[i].address,
                .end = configs[i].address + configs[i].length,
            });
        }

        // Sort final configs by address
        std.sort.insertion(PVM.PageMapConfig, configs, {}, lessThan);
        return configs;
    }

    fn rangeStartLessThan(_: void, a: Range, b: Range) bool {
        return a.start < b.start;
    }

    fn generateRandomPermissions(self: *Self) bool {
        // Example: Generate random RWX permissions
        return self.seed_gen.randomBool();
    }

    fn generateSingleConfig(self: *Self, existing_ranges: *std.ArrayList(Range)) !PVM.PageMapConfig {
        var attempts: u32 = 0;
        while (attempts < 100) : (attempts += 1) {
            // Generate a random page size (aligned to 8 bytes)
            const length = self.seed_gen.randomMemorySize();
            const aligned_length = (length + 7) & ~@as(u32, 7);

            // Generate a random address (aligned to 8 bytes)
            const address = self.seed_gen.randomMemoryAddress();

            // Check for overlaps with existing ranges
            var has_overlap = false;
            for (existing_ranges.items) |range| {
                const new_end = std.math.add(u32, address, aligned_length) catch {
                    has_overlap = true;
                    break;
                };
                if (address < range.end and new_end > range.start) {
                    has_overlap = true;
                    break;
                }
            }

            if (!has_overlap) {
                return PVM.PageMapConfig{
                    .address = address,
                    .length = aligned_length,
                    .is_writable = self.generatePagePermissions(),
                };
            }
        }
        return error.CouldNotGenerateANonOverlappingConfig;
    }

    fn generatePagePermissions(self: *Self) bool {
        // 70% chance of writable pages
        return self.seed_gen.randomIntRange(u8, 0, 99) < 70;
    }

    /// Generate initial memory contents for a page
    pub fn generatePageContents(self: *Self, length: u32) ![]align(8) u8 {
        var contents = try self.allocator.alignedAlloc(u8, 8, length);
        errdefer self.allocator.free(contents);

        // Strategy for content generation:
        // - 40% chance: Fill with zeros
        // - 30% chance: Fill with random data
        // - 30% chance: Fill with pattern (repeating sequence)
        const strategy = self.seed_gen.randomIntRange(u8, 0, 99);
        switch (strategy) {
            0...39 => {
                // Fill with zeros
                @memset(contents, 0);
            },
            40...69 => {
                // Fill with random data
                self.seed_gen.randomBytes(contents);
            },
            else => {
                // Fill with pattern
                const pattern_length = self.seed_gen.randomIntRange(u8, 1, 8);
                const pattern = try self.allocator.alloc(u8, pattern_length);
                defer self.allocator.free(pattern);

                self.seed_gen.randomBytes(pattern);

                var i: usize = 0;
                while (i < contents.len) : (i += 1) {
                    contents[i] = pattern[i % pattern.len];
                }
            },
        }

        return contents;
    }

    // Helper function for sorting page configs
    fn lessThan(_: void, a: PVM.PageMapConfig, b: PVM.PageMapConfig) bool {
        return a.address < b.address;
    }
};

/// Test generation of page configurations
pub fn testMemoryConfigGeneration(allocator: std.mem.Allocator) !void {
    var seed_gen = SeedGenerator.init(42);
    var generator = MemoryConfigGenerator.init(allocator, &seed_gen);

    // Generate and verify configurations
    const configs = try generator.generatePageConfigs();
    defer allocator.free(configs);

    // Verify non-overlapping pages
    for (configs[0 .. configs.len - 1], 0..) |config, i| {
        const next = configs[i + 1];
        std.debug.assert(config.address + config.length <= next.address);
    }

    // Verify alignments
    for (configs) |config| {
        std.debug.assert(config.address % 8 == 0);
        std.debug.assert(config.length % 8 == 0);
    }
}
