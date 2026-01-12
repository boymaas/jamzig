const std = @import("std");
const types = @import("types.zig");
const WorkPackageHash = types.WorkPackageHash;
const HashSet = @import("datastruct/hash_set.zig").HashSet;

pub fn Xi(comptime epoch_size: usize) type {
    return struct {
        entries: [epoch_size]HashSet(WorkPackageHash),
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
            for (self.entries, 0..) |slot_entries, i| {
                cloned.entries[i] = try slot_entries.clone(allocator);
            }
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
            const newest_slot = epoch_size - 1;
            try self.entries[newest_slot].add(self.allocator, work_package_hash);
            try self.global_index.add(self.allocator, work_package_hash);
        }

        pub fn containsWorkPackage(
            self: *const @This(),
            work_package_hash: WorkPackageHash,
        ) bool {
            return self.global_index.contains(work_package_hash);
        }

        pub fn shiftDown(self: *@This()) !void {
            var dropped_slot = self.entries[0];
            for (0..epoch_size - 1) |i| {
                self.entries[i] = self.entries[i + 1];
            }
            self.entries[epoch_size - 1] = HashSet(WorkPackageHash).init();
            var dropped_slot_iter = dropped_slot.iterator();
            while (dropped_slot_iter.next()) |entry| {
                _ = self.global_index.remove(entry.key_ptr.*);
            }
            dropped_slot.deinit(self.allocator);
        }
    };
}

const testing = std.testing;

fn generateWorkPackageHash(seed: u32) WorkPackageHash {
    var hash: WorkPackageHash = [_]u8{0} ** 32;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    random.bytes(&hash);
    return hash;
}

test "Xi - simulation across multiple epochs" {
    const test_epoch_size = 4;
    const num_epochs_to_simulate = 32;
    const packages_per_slot = 6;

    const allocator = testing.allocator;
    var xi = Xi(test_epoch_size).init(allocator);
    defer xi.deinit();

    var active_packages = HashSet(WorkPackageHash).init();
    defer active_packages.deinit(allocator);

    var epoch: u32 = 0;
    var global_seed: u32 = 0;
    while (epoch < num_epochs_to_simulate) : (epoch += 1) {
        std.debug.print("\nSimulating epoch {d}:\n", .{epoch});

        var slot: u32 = 0;
        while (slot < test_epoch_size) : (slot += 1) {
            std.debug.print("  Processing slot {d}:\n", .{slot});

            var package_idx: u32 = 0;
            while (package_idx < packages_per_slot) : (package_idx += 1) {
                const hash = generateWorkPackageHash(global_seed);
                global_seed += 1;

                try xi.addWorkPackage(hash);
                try active_packages.add(allocator, hash);
                std.debug.print("    Added work package with seed {d}\n", .{global_seed - 1});
            }

            var active_iter = active_packages.iterator();
            while (active_iter.next()) |entry| {
                try testing.expect(xi.containsWorkPackage(entry.key_ptr.*));
            }

            try xi.shiftDown();
            std.debug.print("    Performed shift down\n", .{});

            if (global_seed >= (test_epoch_size * packages_per_slot)) {
                for (0..packages_per_slot) |idx| {
                    const expired_seed = global_seed - (test_epoch_size * packages_per_slot) + @as(u32, @intCast(idx));
                    const expired_hash = generateWorkPackageHash(expired_seed);
                    _ = active_packages.remove(expired_hash);

                    std.debug.print("    Expired work package with seed {d}\n", .{expired_seed});
                }
            }
        }

        try testing.expectEqual(active_packages.count(), xi.global_index.count());
    }
}

test "Xi - deep clone with active reports" {
    const test_epoch_size = 4;
    const allocator = testing.allocator;

    var xi = Xi(test_epoch_size).init(allocator);
    defer xi.deinit();

    const hash1 = generateWorkPackageHash(1);
    const hash2 = generateWorkPackageHash(2);
    try xi.addWorkPackage(hash1);
    try xi.addWorkPackage(hash2);

    var cloned = try xi.deepClone(allocator);
    defer cloned.deinit();

    try testing.expect(cloned.containsWorkPackage(hash1));
    try testing.expect(cloned.containsWorkPackage(hash2));
    try testing.expectEqual(xi.global_index.count(), cloned.global_index.count());

    const hash3 = generateWorkPackageHash(3);
    try cloned.addWorkPackage(hash3);
    try testing.expect(cloned.containsWorkPackage(hash3));
    try testing.expect(!xi.containsWorkPackage(hash3));
}
