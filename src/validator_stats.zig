// The Pi component for tracking validator statistics across epochs, following
// the specification from the graypaper. The Pi component is responsible for
// maintaining six key metrics for each validator:
//
//   1. Blocks Produced (b): The number of blocks produced by the validator.
//   2. Tickets Introduced (t): The number of validator tickets introduced.
//   3. Preimages Introduced (p): The number of preimages introduced by the validator.
//   4. Octets Across Preimages (d): The total number of octets across all preimages introduced.
//   5. Reports Guaranteed (g): The number of reports guaranteed by the validator.
//   6. Availability Assurances (a): The number of assurances made by the validator about data availability.
//
const std = @import("std");

const ValidatorIndex = @import("types.zig").ValidatorIndex; // Identifier for each validator

// ValidatorStats tracks the six key metrics as described in the graypaper
const ValidatorStats = struct {
    blocks_produced: u32, // b: Number of blocks produced
    tickets_introduced: u32, // t: Number of validator tickets introduced
    preimages_introduced: u32, // p: Number of preimages introduced
    octets_across_preimages: u32, // d: Total number of octets across preimages
    reports_guaranteed: u32, // g: Number of reports guaranteed
    availability_assurances: u32, // a: Number of availability assurances

    /// Initialize a new ValidatorStats with all metrics set to zero
    pub fn init() ValidatorStats {
        return ValidatorStats{
            .blocks_produced = 0,
            .tickets_introduced = 0,
            .preimages_introduced = 0,
            .octets_across_preimages = 0,
            .reports_guaranteed = 0,
            .availability_assurances = 0,
        };
    }

    /// Increment blocks produced count
    pub fn update_blocks_produced(self: *ValidatorStats, count: u32) void {
        self.blocks_produced += count;
    }

    /// Increment tickets introduced count
    pub fn update_tickets_introduced(self: *ValidatorStats, count: u32) void {
        self.tickets_introduced += count;
    }

    /// Increment preimages introduced count
    pub fn update_preimages_introduced(self: *ValidatorStats, count: u32) void {
        self.preimages_introduced += count;
    }

    /// Increment octets across preimages count
    pub fn update_octets_across_preimages(self: *ValidatorStats, count: u32) void {
        self.octets_across_preimages += count;
    }

    /// Increment reports guaranteed count
    pub fn update_reports_guaranteed(self: *ValidatorStats, count: u32) void {
        self.reports_guaranteed += count;
    }

    /// Increment availability assurances count
    pub fn update_availability_assurances(self: *ValidatorStats, count: u32) void {
        self.availability_assurances += count;
    }
};

/// PiComponent holds the stats for all validators across two epochs
const Pi = struct {
    currentEpochStats: std.AutoArrayHashMap(ValidatorIndex, ValidatorStats), // Stats for the current epoch
    previousEpochStats: std.AutoArrayHashMap(ValidatorIndex, ValidatorStats), // Stats for the previous epoch
    allocator: std.mem.Allocator,

    /// Initialize a new Pi component with empty stats for current and previous epochs
    pub fn init(allocator: std.mem.Allocator) Pi {
        return Pi{
            .currentEpochStats = std.AutoArrayHashMap(ValidatorIndex, ValidatorStats).init(allocator),
            .previousEpochStats = std.AutoArrayHashMap(ValidatorIndex, ValidatorStats).init(allocator),
            .allocator = allocator,
        };
    }

    /// Get or create ValidatorStats for a given validator ID
    pub fn ensureValidator(self: *Pi, id: ValidatorIndex) !*ValidatorStats {
        const result = try self.currentEpochStats.getOrPut(id);
        if (!result.found_existing) {
            result.value_ptr.* = ValidatorStats.init();
        }
        return result.value_ptr;
    }

    /// Move current epoch stats to previous epoch and reset current stats
    pub fn transitionToNextEpoch(self: *Pi) !void {
        self.previousEpochStats = self.currentEpochStats;
        self.currentEpochStats = std.AutoArrayHashMap(ValidatorIndex, ValidatorStats).init(self.allocator);
    }

    /// Clean up allocated resources
    pub fn deinit(self: *Pi) void {
        self.currentEpochStats.deinit();
        self.previousEpochStats.deinit();
    }
};

// | | | |_ __ (_) ||_   _|__  ___| |_ ___
// | | | | '_ \| | __|| |/ _ \/ __| __/ __|
// | |_| | | | | | |_ | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__||_|\___||___/\__|___/

const testing = std.testing;

test "ValidatorStats initialization" {
    const stats = ValidatorStats.init();
    try testing.expectEqual(@as(u32, 0), stats.blocks_produced);
    try testing.expectEqual(@as(u32, 0), stats.tickets_introduced);
    try testing.expectEqual(@as(u32, 0), stats.preimages_introduced);
    try testing.expectEqual(@as(u32, 0), stats.octets_across_preimages);
    try testing.expectEqual(@as(u32, 0), stats.reports_guaranteed);
    try testing.expectEqual(@as(u32, 0), stats.availability_assurances);
}

test "ValidatorStats update methods" {
    var stats = ValidatorStats.init();

    stats.update_blocks_produced(5);
    try testing.expectEqual(@as(u32, 5), stats.blocks_produced);

    stats.update_tickets_introduced(3);
    try testing.expectEqual(@as(u32, 3), stats.tickets_introduced);

    stats.update_preimages_introduced(2);
    try testing.expectEqual(@as(u32, 2), stats.preimages_introduced);

    stats.update_octets_across_preimages(100);
    try testing.expectEqual(@as(u32, 100), stats.octets_across_preimages);

    stats.update_reports_guaranteed(1);
    try testing.expectEqual(@as(u32, 1), stats.reports_guaranteed);

    stats.update_availability_assurances(4);
    try testing.expectEqual(@as(u32, 4), stats.availability_assurances);

    // Test multiple updates
    stats.update_blocks_produced(3);
    try testing.expectEqual(@as(u32, 8), stats.blocks_produced);
}

test "Pi initialization" {
    const allocator = std.testing.allocator;

    var pi = Pi.init(allocator);
    defer pi.deinit();

    try testing.expectEqual(@as(usize, 0), pi.currentEpochStats.count());
    try testing.expectEqual(@as(usize, 0), pi.previousEpochStats.count());
}

test "Pi ensureValidator" {
    const allocator = std.testing.allocator;

    var pi = Pi.init(allocator);
    defer pi.deinit();

    const validator_id: ValidatorIndex = 1;
    const stats = try pi.ensureValidator(validator_id);

    try testing.expectEqual(@as(usize, 1), pi.currentEpochStats.count());
    try testing.expectEqual(@as(u32, 0), stats.blocks_produced);

    // Ensure getting the same validator doesn't create a new entry
    const same_stats = try pi.ensureValidator(validator_id);
    try testing.expectEqual(@as(usize, 1), pi.currentEpochStats.count());
    try testing.expectEqual(stats, same_stats);

    // Update stats and check if it's reflected
    stats.update_blocks_produced(5);
    try testing.expectEqual(@as(u32, 5), same_stats.blocks_produced);

    // Re-ensure the validator and check if it shows the updated blocks
    const re_ensured_stats = try pi.ensureValidator(validator_id);
    try testing.expectEqual(@as(u32, 5), re_ensured_stats.blocks_produced);
    try testing.expectEqual(stats, re_ensured_stats);
}

test "Pi transitionToNextEpoch" {
    const allocator = std.testing.allocator;

    var pi = Pi.init(allocator);
    defer pi.deinit();

    // Add some data to current epoch
    const validator1: ValidatorIndex = 1;
    const validator2: ValidatorIndex = 2;
    var stats1 = try pi.ensureValidator(validator1);
    var stats2 = try pi.ensureValidator(validator2);
    stats1.update_blocks_produced(5);
    stats2.update_tickets_introduced(3);

    try testing.expectEqual(@as(usize, 2), pi.currentEpochStats.count());
    try testing.expectEqual(@as(usize, 0), pi.previousEpochStats.count());

    // Transition to next epoch
    try pi.transitionToNextEpoch();

    // Check if data moved to previous epoch and current epoch is reset
    try testing.expectEqual(@as(usize, 0), pi.currentEpochStats.count());
    try testing.expectEqual(@as(usize, 2), pi.previousEpochStats.count());

    if (pi.previousEpochStats.get(validator1)) |prev_stats1| {
        try testing.expectEqual(@as(u32, 5), prev_stats1.blocks_produced);
    } else {
        try testing.expect(false);
    }

    if (pi.previousEpochStats.get(validator2)) |prev_stats2| {
        try testing.expectEqual(@as(u32, 3), prev_stats2.tickets_introduced);
    } else {
        try testing.expect(false);
    }
}
