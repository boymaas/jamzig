//  The accumulated_reports module implements the ξ (Xi) data structure, which manages
//  work package tracking across epochs in a blockchain system. The Xi structure maintains
//  a sliding window of work package hashes, where each slot represents a time period
//  within an epoch.
//
//  Key features:
//  - Maintains an array of epoch_size slots, each containing a set of work package hashes
//  - Uses a global index for O(1) lookups across all epochs
//  - Implements a shifting mechanism where entries move down one position with each new block
//  - Automatically expires work packages after they've been in the system for one full epoch
//
//  The structure follows these key invariants:
//  1. A work package hash can only appear in one slot at a time
//  2. New work packages are always added to the newest slot (epoch_size - 1)
//  3. When shifting occurs, the oldest slot (0) is dropped, and all other slots move down
//  4. The global index maintains a unified view of all work packages across all slots

const std = @import("std");
const types = @import("types.zig");
const WorkPackageHash = types.WorkPackageHash;
const HashSet = @import("datastruct/hash_set.zig").HashSet;

pub fn Xi(comptime epoch_size: usize) type {
    return struct {
        // Array of sets, each containing work package hashes for a specific time slot
        entries: [epoch_size]HashSet(WorkPackageHash),
        // Global index tracking all work packages across all slots
        global_index: HashSet(WorkPackageHash),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .entries = [_]HashSet(WorkPackageHash){HashSet(WorkPackageHash).init()} ** epoch_size,
                .global_index = HashSet(WorkPackageHash).init(),
                .allocator = allocator,
            };
        }

        pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
            var cloned = @This(){
                .entries = undefined,
                .global_index = HashSet(WorkPackageHash).init(),
                .allocator = allocator,
            };
            // Clone the entries array
            for (self.entries, 0..) |slot_entries, i| {
                cloned.entries[i] = try slot_entries.clone(allocator);
            }
            // Clone the global index
            cloned.global_index = try self.global_index.clone(allocator);
            return cloned;
        }

        pub fn deinit(self: *@This()) void {
            for (&self.entries) |*slot_entries| {
                slot_entries.deinit(self.allocator);
            }
            self.global_index.deinit(self.allocator);
            self.* = undefined;
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

        pub fn addWorkPackage(
            self: *@This(),
            work_package_hash: WorkPackageHash,
        ) !void {
            // Add to the newest time slot (last slot in the array)
            const newest_slot = epoch_size - 1;
            try self.entries[newest_slot].add(self.allocator, work_package_hash);
            // Add to the global index
            try self.global_index.add(self.allocator, work_package_hash);
        }

        pub fn containsWorkPackage(
            self: *const @This(),
            work_package_hash: WorkPackageHash,
        ) bool {
            return self.global_index.contains(work_package_hash);
        }

        pub fn shiftDown(self: *@This()) !void {
            // Store the first slot temporarily since it will be dropped
            var dropped_slot = self.entries[0];
            // Shift all entries down by value
            for (0..epoch_size - 1) |i| {
                self.entries[i] = self.entries[i + 1];
            }
            // Clear the last slot (it's now empty for new entries)
            self.entries[epoch_size - 1] = HashSet(WorkPackageHash).init();
            // Update global index by removing dropped entries
            // Workpackage hashes are unique over the Xi domain
            var dropped_slot_iter = dropped_slot.iterator();
            while (dropped_slot_iter.next()) |entry| {
                _ = self.global_index.remove(entry.key_ptr.*);
            }
            // Clean up the dropped slot
            dropped_slot.deinit(self.allocator);
        }
    };
}

const testing = std.testing;

// Helper function to generate deterministic work package hashes for testing
fn generateWorkPackageHash(seed: u32) WorkPackageHash {
    var hash: WorkPackageHash = [_]u8{0} ** 32;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    random.bytes(&hash);
    return hash;
}

test "Xi - simulation across multiple epochs" {
    // Test configuration
    const test_epoch_size = 4;
    const num_epochs_to_simulate = 32;
    const packages_per_slot = 6;

    const allocator = testing.allocator;
    var xi = Xi(test_epoch_size).init(allocator);
    defer xi.deinit();

    // Keep track of active work packages for verification
    var active_packages = HashSet(WorkPackageHash).init();
    defer active_packages.deinit(allocator);

    // Simulate multiple epochs
    var epoch: u32 = 0;
    var global_seed: u32 = 0;
    while (epoch < num_epochs_to_simulate) : (epoch += 1) {
        std.debug.print("\nSimulating epoch {d}:\n", .{epoch});

        // Simulate each slot in the epoch
        var slot: u32 = 0;
        while (slot < test_epoch_size) : (slot += 1) {
            std.debug.print("  Processing slot {d}:\n", .{slot});

            // Add new work packages
            var package_idx: u32 = 0;
            while (package_idx < packages_per_slot) : (package_idx += 1) {
                const hash = generateWorkPackageHash(global_seed);
                global_seed += 1;

                try xi.addWorkPackage(hash);
                try active_packages.add(allocator, hash);
                std.debug.print("    Added work package with seed {d}\n", .{global_seed - 1});
            }

            // Verify all active packages are in the global index
            var active_iter = active_packages.iterator();
            while (active_iter.next()) |entry| {
                try testing.expect(xi.containsWorkPackage(entry.key_ptr.*));
            }

            try xi.shiftDown();
            std.debug.print("    Performed shift down\n", .{});

            // Simulate shiftDown and compare
            if (global_seed >= (test_epoch_size * packages_per_slot)) {
                for (0..packages_per_slot) |idx| {
                    const expired_seed = global_seed - (test_epoch_size * packages_per_slot) + @as(u32, @intCast(idx));
                    const expired_hash = generateWorkPackageHash(expired_seed);
                    _ = active_packages.remove(expired_hash);

                    std.debug.print("    Expired work package with seed {d}\n", .{expired_seed});
                }
            }
        }

        // Verify global index size matches active packages
        try testing.expectEqual(active_packages.count(), xi.global_index.count());
    }
}

test "Xi - deep clone with active reports" {
    const test_epoch_size = 4;
    const allocator = testing.allocator;

    var xi = Xi(test_epoch_size).init(allocator);
    defer xi.deinit();

    // Add some work packages
    const hash1 = generateWorkPackageHash(1);
    const hash2 = generateWorkPackageHash(2);
    try xi.addWorkPackage(hash1);
    try xi.addWorkPackage(hash2);

    // Create a deep clone
    var cloned = try xi.deepClone(allocator);
    defer cloned.deinit();

    // Verify the clone has the same content
    try testing.expect(cloned.containsWorkPackage(hash1));
    try testing.expect(cloned.containsWorkPackage(hash2));
    try testing.expectEqual(xi.global_index.count(), cloned.global_index.count());

    // Modify the clone and verify original is unchanged
    const hash3 = generateWorkPackageHash(3);
    try cloned.addWorkPackage(hash3);
    try testing.expect(cloned.containsWorkPackage(hash3));
    try testing.expect(!xi.containsWorkPackage(hash3));
}
