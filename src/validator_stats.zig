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
pub const ValidatorStats = struct {
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
    pub fn updateBlocksProduced(self: *ValidatorStats, count: u32) void {
        self.blocks_produced += count;
    }

    /// Increment tickets introduced count
    pub fn updateTicketsIntroduced(self: *ValidatorStats, count: u32) void {
        self.tickets_introduced += count;
    }

    /// Increment preimages introduced count
    pub fn updatePreimagesIntroduced(self: *ValidatorStats, count: u32) void {
        self.preimages_introduced += count;
    }

    /// Increment octets across preimages count
    pub fn updateOctetsAcrossPreimages(self: *ValidatorStats, count: u32) void {
        self.octets_across_preimages += count;
    }

    /// Increment reports guaranteed count
    pub fn updateReportsGuaranteed(self: *ValidatorStats, count: u32) void {
        self.reports_guaranteed += count;
    }

    /// Increment availability assurances count
    pub fn updateAvailabilityAssurances(self: *ValidatorStats, count: u32) void {
        self.availability_assurances += count;
    }

    pub fn jsonStringify(stats: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("blocks_produced");
        try jw.write(stats.blocks_produced);
        try jw.objectField("tickets_introduced");
        try jw.write(stats.tickets_introduced);
        try jw.objectField("preimages_introduced");
        try jw.write(stats.preimages_introduced);
        try jw.objectField("octets_across_preimages");
        try jw.write(stats.octets_across_preimages);
        try jw.objectField("reports_guaranteed");
        try jw.write(stats.reports_guaranteed);
        try jw.objectField("availability_assurances");
        try jw.write(stats.availability_assurances);
        try jw.endObject();
    }
};

/// PiComponent holds the stats for all validators across two epochs
pub const Pi = struct {
    current_epoch_stats: std.ArrayList(ValidatorStats), // Stats for the current epoch
    previous_epoch_stats: std.ArrayList(ValidatorStats), // Stats for the previous epoch
    allocator: std.mem.Allocator,
    validator_count: usize,

    fn initValidatorStats(allocator: std.mem.Allocator, validator_count: usize) !std.ArrayList(ValidatorStats) {
        var stats = try std.ArrayList(ValidatorStats).initCapacity(allocator, validator_count);
        var i: usize = 0;
        while (i < validator_count) : (i += 1) {
            try stats.append(ValidatorStats.init());
        }
        return stats;
    }

    /// Initialize a new Pi component with zeroed-out stats for current and previous epochs
    pub fn init(allocator: std.mem.Allocator, validator_count: usize) !Pi {
        return Pi{
            .current_epoch_stats = try Pi.initValidatorStats(allocator, validator_count),
            .previous_epoch_stats = try Pi.initValidatorStats(allocator, validator_count),
            .allocator = allocator,
            .validator_count = validator_count,
        };
    }

    /// Get ValidatorStats for a given validator ID in the current epoch
    pub fn getValidatorStats(self: *Pi, id: ValidatorIndex) !*ValidatorStats {
        if (id >= self.validator_count) {
            return error.ValidatorIndexOutOfBounds;
        }
        return &self.current_epoch_stats.items[id];
    }

    /// Move current epoch stats to previous epoch and reset current stats
    pub fn transitionToNextEpoch(self: *Pi) !void {
        self.previous_epoch_stats.deinit();
        self.previous_epoch_stats = self.current_epoch_stats;
        self.current_epoch_stats = try Pi.initValidatorStats(self.allocator, self.validator_count);
    }

    /// Clean up allocated resources
    pub fn deinit(self: *Pi) void {
        self.current_epoch_stats.deinit();
        self.previous_epoch_stats.deinit();
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("current_epoch_stats");
        try jw.beginArray();
        for (self.current_epoch_stats.items) |*stats| {
            try stats.jsonStringify(jw);
        }
        try jw.endArray();

        try jw.objectField("previous_epoch_stats");
        try jw.beginArray();
        for (self.previous_epoch_stats.items) |*stats| {
            try stats.jsonStringify(jw);
        }
        try jw.endArray();

        try jw.endObject();
    }
};

//  _   _       _ _  _____         _
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

    stats.updateBlocksProduced(5);
    try testing.expectEqual(@as(u32, 5), stats.blocks_produced);

    stats.updateTicketsIntroduced(3);
    try testing.expectEqual(@as(u32, 3), stats.tickets_introduced);

    stats.updatePreimagesIntroduced(2);
    try testing.expectEqual(@as(u32, 2), stats.preimages_introduced);

    stats.updateOctetsAcrossPreimages(100);
    try testing.expectEqual(@as(u32, 100), stats.octets_across_preimages);

    stats.updateReportsGuaranteed(1);
    try testing.expectEqual(@as(u32, 1), stats.reports_guaranteed);

    stats.updateAvailabilityAssurances(4);
    try testing.expectEqual(@as(u32, 4), stats.availability_assurances);

    // Test multiple updates
    stats.updateBlocksProduced(3);
    try testing.expectEqual(@as(u32, 8), stats.blocks_produced);
}

test "Pi initialization" {
    const allocator = std.testing.allocator;
    const validator_count: usize = 5;

    var pi = try Pi.init(allocator, validator_count);
    defer pi.deinit();

    try testing.expectEqual(validator_count, pi.current_epoch_stats.items.len);
    try testing.expectEqual(validator_count, pi.previous_epoch_stats.items.len);

    // Check if all stats are zeroed out
    for (pi.current_epoch_stats.items) |stats| {
        try testing.expectEqual(@as(u32, 0), stats.blocks_produced);
        try testing.expectEqual(@as(u32, 0), stats.tickets_introduced);
        try testing.expectEqual(@as(u32, 0), stats.preimages_introduced);
        try testing.expectEqual(@as(u32, 0), stats.octets_across_preimages);
        try testing.expectEqual(@as(u32, 0), stats.reports_guaranteed);
        try testing.expectEqual(@as(u32, 0), stats.availability_assurances);
    }

    for (pi.previous_epoch_stats.items) |stats| {
        try testing.expectEqual(@as(u32, 0), stats.blocks_produced);
        try testing.expectEqual(@as(u32, 0), stats.tickets_introduced);
        try testing.expectEqual(@as(u32, 0), stats.preimages_introduced);
        try testing.expectEqual(@as(u32, 0), stats.octets_across_preimages);
        try testing.expectEqual(@as(u32, 0), stats.reports_guaranteed);
        try testing.expectEqual(@as(u32, 0), stats.availability_assurances);
    }
}

test "Pi ensure_validator" {
    const allocator = std.testing.allocator;

    var pi = try Pi.init(allocator, 6);
    defer pi.deinit();

    const validator_id: ValidatorIndex = 1;
    const stats = try pi.getValidatorStats(validator_id);

    try testing.expectEqual(@as(u32, 0), stats.blocks_produced);

    // Ensure getting the same validator doesn't create a new entry
    const same_stats = try pi.getValidatorStats(validator_id);
    try testing.expectEqual(stats, same_stats);

    // Update stats and check if it's reflected
    stats.updateBlocksProduced(5);
    try testing.expectEqual(@as(u32, 5), same_stats.blocks_produced);

    // Re-ensure the validator and check if it shows the updated blocks
    const re_ensured_stats = try pi.getValidatorStats(validator_id);
    try testing.expectEqual(@as(u32, 5), re_ensured_stats.blocks_produced);
    try testing.expectEqual(stats, re_ensured_stats);
}

test "Pi transition_to_next_epoch" {
    const allocator = std.testing.allocator;

    var pi = try Pi.init(allocator, 6);
    defer pi.deinit();

    // Add some data to current epoch
    const validator1: ValidatorIndex = 1;
    const validator2: ValidatorIndex = 2;
    var stats1 = try pi.getValidatorStats(validator1);
    var stats2 = try pi.getValidatorStats(validator2);
    stats1.updateBlocksProduced(5);
    stats2.updateTicketsIntroduced(3);

    // Transition to next epoch
    try pi.transitionToNextEpoch();

    // Check if previous epoch stats are correct
    try testing.expectEqual(@as(u32, 5), pi.previous_epoch_stats.items[validator1].blocks_produced);
    try testing.expectEqual(@as(u32, 3), pi.previous_epoch_stats.items[validator2].tickets_introduced);

    // Check if current epoch stats are zeroed out
    // Check if all stats are zeroed out
    for (pi.current_epoch_stats.items) |stats| {
        try testing.expectEqual(@as(u32, 0), stats.blocks_produced);
        try testing.expectEqual(@as(u32, 0), stats.tickets_introduced);
        try testing.expectEqual(@as(u32, 0), stats.preimages_introduced);
        try testing.expectEqual(@as(u32, 0), stats.octets_across_preimages);
        try testing.expectEqual(@as(u32, 0), stats.reports_guaranteed);
        try testing.expectEqual(@as(u32, 0), stats.availability_assurances);
    }
}
