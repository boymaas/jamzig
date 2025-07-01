// The Pi component for tracking validator statistics
const std = @import("std");

const ValidatorIndex = @import("types.zig").ValidatorIndex;
const ServiceId = @import("types.zig").ServiceId;
const U16 = @import("types.zig").U16;
const U32 = @import("types.zig").U32;
const U64 = @import("types.zig").U64;

// ValidatorStats tracks the six key metrics as described in the graypaper
pub const ValidatorStats = struct {
    blocks_produced: U32 = 0,
    tickets_introduced: U32 = 0,
    preimages_introduced: U32 = 0,
    octets_across_preimages: U32 = 0,
    reports_guaranteed: U32 = 0,
    availability_assurances: U32 = 0,

    pub fn init() ValidatorStats {
        return ValidatorStats{};
    }

    pub fn updateBlocksProduced(self: *ValidatorStats, count: U32) void {
        self.blocks_produced += count;
    }

    pub fn updateTicketsIntroduced(self: *ValidatorStats, count: U32) void {
        self.tickets_introduced += count;
    }

    pub fn updatePreimagesIntroduced(self: *ValidatorStats, count: U32) void {
        self.preimages_introduced += count;
    }

    pub fn updateOctetsAcrossPreimages(self: *ValidatorStats, count: U32) void {
        self.octets_across_preimages += count;
    }

    pub fn updateReportsGuaranteed(self: *ValidatorStats, count: U32) void {
        self.reports_guaranteed += count;
    }

    pub fn updateAvailabilityAssurances(self: *ValidatorStats, count: U32) void {
        self.availability_assurances += count;
    }

    pub fn jsonStringify(stats: *const @This(), jw: anytype) !void {
        try @import("state_json/validator_stats.zig").jsonStringifyValidatorStats(stats, jw);
    }
};

pub const CoreActivityRecord = struct {
    // Amount of bytes which are placed into either Audits or Segments DA.
    // This includes the work-bundle (including all extrinsics and
    // imports) as well as all (exported) segments.
    da_load: U32,
    // Number of validators which formed super-majority for assurance.
    popularity: U16,
    // Number of segments imported from DA made by core for reported work.
    imports: U16,
    // Number of segments exported into DA made by core for reported work.
    exports: U16,
    // Total number of extrinsics used by core for reported work.
    extrinsic_count: U16,
    //  Total size of extrinsics used by core for reported work.
    extrinsic_size: U32,
    // The work-bundle size. This is the size of data being placed into Audits DA by the core.
    bundle_size: U32,
    // Total gas consumed by core for reported work. Includes all
    // refinement and authorizations.
    gas_used: U64,

    pub fn init() CoreActivityRecord {
        return CoreActivityRecord{
            .da_load = 0,
            .popularity = 0,
            .imports = 0,
            .extrinsic_count = 0,
            .extrinsic_size = 0,
            .exports = 0,
            .bundle_size = 0,
            .gas_used = 0,
        };
    }

    pub fn encode(self: *const @This(), _: anytype, writer: anytype) !void {
        const codec = @import("codec.zig");

        // Encode each field using variable-length integer encoding
        try codec.writeInteger(self.da_load, writer);
        try codec.writeInteger(self.popularity, writer);
        try codec.writeInteger(self.imports, writer);
        try codec.writeInteger(self.exports, writer);
        try codec.writeInteger(self.extrinsic_size, writer);
        try codec.writeInteger(self.extrinsic_count, writer);
        try codec.writeInteger(self.bundle_size, writer);
        try codec.writeInteger(self.gas_used, writer);
    }

    pub fn decode(_: anytype, reader: anytype, _: anytype) !@This() {
        const codec = @import("codec.zig");

        // Read each field using variable-length integer decoding
        // and truncate to the appropriate size
        const da_load = @as(U32, @truncate(try codec.readInteger(reader)));
        const popularity = @as(U16, @truncate(try codec.readInteger(reader)));
        const imports = @as(U16, @truncate(try codec.readInteger(reader)));
        const exports = @as(U16, @truncate(try codec.readInteger(reader)));
        const extrinsic_size = @as(U32, @truncate(try codec.readInteger(reader)));
        const extrinsic_count = @as(U16, @truncate(try codec.readInteger(reader)));
        const bundle_size = @as(U32, @truncate(try codec.readInteger(reader)));
        const gas_used = try codec.readInteger(reader);

        return @This(){
            .gas_used = gas_used,
            .imports = imports,
            .extrinsic_count = extrinsic_count,
            .extrinsic_size = extrinsic_size,
            .exports = exports,
            .bundle_size = bundle_size,
            .da_load = da_load,
            .popularity = popularity,
        };
    }
};

pub const ServiceActivityRecord = struct {
    provided_count: U16 = 0,
    provided_size: U32 = 0,
    refinement_count: U32 = 0,
    refinement_gas_used: U64 = 0,
    imports: U32 = 0,
    exports: U32 = 0,
    extrinsic_size: U32 = 0,
    extrinsic_count: U32 = 0,
    accumulate_count: U32 = 0,
    accumulate_gas_used: U64 = 0,
    on_transfers_count: U32 = 0,
    on_transfers_gas_used: U64 = 0,

    pub fn init() ServiceActivityRecord {
        return ServiceActivityRecord{};
    }

    pub fn encode(self: *const @This(), _: anytype, writer: anytype) !void {
        const codec = @import("codec.zig");

        // Encode each field using variable-length integer encoding
        try codec.writeInteger(self.provided_count, writer);
        try codec.writeInteger(self.provided_size, writer);
        try codec.writeInteger(self.refinement_count, writer);
        try codec.writeInteger(self.refinement_gas_used, writer);
        try codec.writeInteger(self.imports, writer);
        try codec.writeInteger(self.exports, writer);
        try codec.writeInteger(self.extrinsic_size, writer);
        try codec.writeInteger(self.extrinsic_count, writer);
        try codec.writeInteger(self.accumulate_count, writer);
        try codec.writeInteger(self.accumulate_gas_used, writer);
        try codec.writeInteger(self.on_transfers_count, writer);
        try codec.writeInteger(self.on_transfers_gas_used, writer);
    }

    pub fn decode(_: anytype, reader: anytype, _: std.mem.Allocator) !@This() {
        const codec = @import("codec.zig");

        // Read each field using variable-length integer decoding
        // and truncate to the appropriate size
        const provided_count = @as(U16, @truncate(try codec.readInteger(reader)));
        const provided_size = @as(U32, @truncate(try codec.readInteger(reader)));
        const refinement_count = @as(U32, @truncate(try codec.readInteger(reader)));
        const refinement_gas_used = try codec.readInteger(reader);
        const imports = @as(U32, @truncate(try codec.readInteger(reader)));
        const exports = @as(U32, @truncate(try codec.readInteger(reader)));
        const extrinsic_size = @as(U32, @truncate(try codec.readInteger(reader)));
        const extrinsic_count = @as(U32, @truncate(try codec.readInteger(reader)));
        const accumulate_count = @as(U32, @truncate(try codec.readInteger(reader)));
        const accumulate_gas_used = try codec.readInteger(reader);
        const on_transfers_count = @as(U32, @truncate(try codec.readInteger(reader)));
        const on_transfers_gas_used = try codec.readInteger(reader);

        return @This(){
            .provided_count = provided_count,
            .provided_size = provided_size,
            .refinement_count = refinement_count,
            .refinement_gas_used = refinement_gas_used,
            .imports = imports,
            .extrinsic_count = extrinsic_count,
            .extrinsic_size = extrinsic_size,
            .exports = exports,
            .accumulate_count = accumulate_count,
            .accumulate_gas_used = accumulate_gas_used,
            .on_transfers_count = on_transfers_count,
            .on_transfers_gas_used = on_transfers_gas_used,
        };
    }
};

/// PiComponent holds the comprehensive statistics for the system
pub const Pi = struct {
    current_epoch_stats: std.ArrayList(ValidatorStats),
    previous_epoch_stats: std.ArrayList(ValidatorStats),
    core_stats: std.ArrayList(CoreActivityRecord),
    service_stats: std.AutoHashMap(ServiceId, ServiceActivityRecord),
    allocator: std.mem.Allocator,
    validator_count: usize,
    core_count: usize,

    fn initValidatorStats(allocator: std.mem.Allocator, validator_count: usize) !std.ArrayList(ValidatorStats) {
        var stats = try std.ArrayList(ValidatorStats).initCapacity(allocator, validator_count);
        var i: usize = 0;
        while (i < validator_count) : (i += 1) {
            try stats.append(ValidatorStats.init());
        }
        return stats;
    }

    fn initCoreStats(allocator: std.mem.Allocator, core_count: usize) !std.ArrayList(CoreActivityRecord) {
        var stats = try std.ArrayList(CoreActivityRecord).initCapacity(allocator, core_count);
        var i: usize = 0;
        while (i < core_count) : (i += 1) {
            try stats.append(CoreActivityRecord.init());
        }
        return stats;
    }

    /// Initialize a new Pi component with zeroed-out stats
    pub fn init(allocator: std.mem.Allocator, validator_count: usize, core_count: usize) !Pi {
        return Pi{
            .current_epoch_stats = try Pi.initValidatorStats(allocator, validator_count),
            .previous_epoch_stats = try Pi.initValidatorStats(allocator, validator_count),
            .core_stats = try Pi.initCoreStats(allocator, core_count),
            .service_stats = std.AutoHashMap(ServiceId, ServiceActivityRecord).init(allocator),
            .allocator = allocator,
            .validator_count = validator_count,
            .core_count = core_count,
        };
    }

    /// Get ValidatorStats for a given validator ID in the current epoch
    pub fn getValidatorStats(self: *Pi, id: ValidatorIndex) !*ValidatorStats {
        if (id >= self.validator_count) {
            return error.ValidatorIndexOutOfBounds;
        }
        return &self.current_epoch_stats.items[id];
    }

    /// Get CoreActivityRecord for a given core ID
    pub fn getCoreStats(self: *Pi, core_id: U16) !*CoreActivityRecord {
        if (core_id >= self.core_count) {
            return error.CoreIndexOutOfBounds;
        }
        return &self.core_stats.items[core_id];
    }

    /// Get or create ServiceActivityRecord for a given service ID
    pub fn getOrCreateServiceStats(self: *Pi, service_id: ServiceId) !*ServiceActivityRecord {
        // Try to get the entry first
        if (self.service_stats.getPtr(service_id)) |record| {
            return record;
        }

        // Service not found, create a new entry
        try self.service_stats.put(service_id, ServiceActivityRecord.init());
        return self.service_stats.getPtr(service_id).?;
    }

    /// Move current epoch stats to previous epoch and reset current stats
    pub fn transitionToNextEpoch(self: *Pi) !void {
        self.previous_epoch_stats.deinit();
        self.previous_epoch_stats = self.current_epoch_stats;
        self.current_epoch_stats = try Pi.initValidatorStats(self.allocator, self.validator_count);

        // Clear core and service stats for the new epoch
        for (self.core_stats.items) |*core_stat| {
            core_stat.* = CoreActivityRecord.init();
        }

        // Clear service stats for the new epoch
        var service_iter = self.service_stats.iterator();
        while (service_iter.next()) |entry| {
            try self.service_stats.put(entry.key_ptr.*, ServiceActivityRecord.init());
        }
    }

    /// Clear the per block stats
    pub fn clearPerBlockStats(self: *Pi) void {
        for (self.core_stats.items) |*stat| {
            stat.* = CoreActivityRecord.init();
        }
        self.service_stats.clearRetainingCapacity();
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        // Create new ArrayLists
        var current_stats = try std.ArrayList(ValidatorStats).initCapacity(allocator, self.validator_count);
        var previous_stats = try std.ArrayList(ValidatorStats).initCapacity(allocator, self.validator_count);
        var cores = try std.ArrayList(CoreActivityRecord).initCapacity(allocator, self.core_count);
        var services = std.AutoHashMap(ServiceId, ServiceActivityRecord).init(allocator);

        // Deep clone each ValidatorStats instance from current epoch
        for (self.current_epoch_stats.items) |stats| {
            try current_stats.append(stats);
        }

        // Deep clone each ValidatorStats instance from previous epoch
        for (self.previous_epoch_stats.items) |stats| {
            try previous_stats.append(stats);
        }

        // Deep clone each CoreActivityRecord
        for (self.core_stats.items) |stats| {
            try cores.append(stats);
        }

        // Deep clone each ServiceActivityRecord
        var service_iter = self.service_stats.iterator();
        while (service_iter.next()) |entry| {
            try services.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Return new Pi instance with cloned data
        return @This(){
            .current_epoch_stats = current_stats,
            .previous_epoch_stats = previous_stats,
            .core_stats = cores,
            .service_stats = services,
            .allocator = allocator,
            .validator_count = self.validator_count,
            .core_count = self.core_count,
        };
    }

    /// Clean up allocated resources
    pub fn deinit(self: *Pi) void {
        self.current_epoch_stats.deinit();
        self.previous_epoch_stats.deinit();
        self.core_stats.deinit();
        self.service_stats.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try @import("state_json/validator_stats.zig").jsonStringifyPi(self, jw);
    }

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try @import("state_format/pi.zig").formatPi(self, fmt, options, writer);
    }
};
