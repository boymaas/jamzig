const std = @import("std");
const services = @import("services.zig");

const Delta = services.Delta;
const ServiceAccount = services.ServiceAccount;
const ServiceId = services.ServiceId;
const Allocator = std.mem.Allocator;

/// DeltaSnapshot provides a copy-on-write wrapper around the Delta state.
/// It allows modifications to services without affecting the original state until commit.
///
/// This is used for implementing the dual-domain context in the JAM accumulation process,
/// where we need to track both regular and exceptional state for potential rollback.
pub const DeltaSnapshot = struct {
    /// The original Delta state (immutable reference)
    original: *const Delta,

    /// Hash map of services that have been modified in this snapshot
    modified_services: std.AutoHashMap(ServiceId, ServiceAccount),

    /// Set of service IDs that have been marked for deletion
    deleted_services: std.AutoHashMap(ServiceId, void),

    /// The allocator used for the snapshot's internal data structures
    allocator: Allocator,

    /// Initialize a new DeltaSnapshot from an existing Delta state
    pub fn init(original: *const Delta) DeltaSnapshot {
        return .{
            .original = original,
            .modified_services = std.AutoHashMap(ServiceId, ServiceAccount).init(original.allocator),
            .deleted_services = std.AutoHashMap(ServiceId, void).init(original.allocator),
            .allocator = original.allocator,
        };
    }

    /// Free all resources used by the snapshot
    pub fn deinit(self: *DeltaSnapshot) void {
        // Clean up modified services
        var it = self.modified_services.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.modified_services.deinit();

        // Clean up deleted services tracking
        self.deleted_services.deinit();

        self.* = undefined;
    }

    /// Get a read-only reference to a service
    /// Returns null if the service doesn't exist or has been deleted
    pub fn getReadOnly(self: *const DeltaSnapshot, id: ServiceId) ?*const ServiceAccount {
        // Check if the service is marked for deletion
        if (self.deleted_services.contains(id)) {
            return null;
        }

        // Check if we have a modified copy
        if (self.modified_services.getPtr(id)) |account| {
            return account;
        }

        // Fall back to the original state
        return if (self.original.getAccount(id)) |account| account else null;
    }

    /// Check if a service exists in this snapshot
    pub fn contains(self: *const DeltaSnapshot, id: ServiceId) bool {
        if (self.deleted_services.contains(id)) {
            return false;
        }

        return self.modified_services.contains(id) or
            self.original.accounts.contains(id);
    }

    /// Get a mutable reference to a service
    /// This will create a copy of the service if it exists in the original state
    /// Returns null if the service doesn't exist
    pub fn getMutable(self: *DeltaSnapshot, id: ServiceId) !?*ServiceAccount {
        // Check if service is marked for deletion
        if (self.deleted_services.contains(id)) {
            return null;
        }

        // Check if we already have a modified copy
        if (self.modified_services.getPtr(id)) |account| {
            return account;
        }

        // Check if it exists in the original state
        if (self.original.getAccount(id)) |account| {
            // Add to modified services
            try self.modified_services.put(id, try account.deepClone(self.allocator));
            return self.modified_services.getPtr(id).?;
        }

        return null;
    }

    /// Create a new service in this snapshot
    pub fn createService(self: *DeltaSnapshot, id: ServiceId) !*ServiceAccount {
        // Check if service already exists
        if (self.contains(id)) {
            return error.ServiceAlreadyExists;
        }

        // Remove from deleted if it was there
        _ = self.deleted_services.remove(id);

        // Create a new service
        var new_account = ServiceAccount.init(self.allocator);
        errdefer new_account.deinit();

        // Add to modified services
        try self.modified_services.put(id, new_account);
        return self.modified_services.getPtr(id).?;
    }

    /// Mark a service for deletion
    pub fn removeService(self: *DeltaSnapshot, id: ServiceId) !bool {
        // Check if service exists
        if (!self.contains(id)) {
            return false;
        }

        // Remove from modified services if it's there
        if (self.modified_services.fetchRemove(id)) |entry| {
            @constCast(&entry.value).deinit();
        }

        // Mark for deletion
        try self.deleted_services.put(id, {});
        return true;
    }

    /// Get the set of all service IDs that have been modified or deleted
    pub fn getChangedServiceIds(self: *const DeltaSnapshot) ![]ServiceId {
        const total_changes = self.modified_services.count() + self.deleted_services.count();

        var result = try self.allocator.alloc(ServiceId, total_changes);
        errdefer self.allocator.free(result);

        var index: usize = 0;

        // Add modified services
        var modified_it = self.modified_services.keyIterator();
        while (modified_it.next()) |id| {
            result[index] = id.*;
            index += 1;
        }

        // Add deleted services
        var deleted_it = self.deleted_services.keyIterator();
        while (deleted_it.next()) |id| {
            result[index] = id.*;
            index += 1;
        }

        return result;
    }

    /// Check if the snapshot has any changes
    pub fn hasChanges(self: *const DeltaSnapshot) bool {
        return self.modified_services.count() > 0 or self.deleted_services.count() > 0;
    }

    /// Apply all changes from this snapshot to the destination Delta
    pub fn commit(self: *DeltaSnapshot) !void {
        var destination = @constCast(self.original);
        // First handle deleted services
        var deleted_it = self.deleted_services.keyIterator();
        while (deleted_it.next()) |id| {
            if (destination.getAccount(id.*)) |account| {
                account.deinit();
                _ = destination.accounts.remove(id.*);
            }
        }

        // Then apply modified services
        var modified_it = self.modified_services.iterator();
        while (modified_it.next()) |entry| {
            const id = entry.key_ptr.*;

            // If the service already exists in the destination, remove it first
            if (destination.getAccount(id)) |account| {
                account.deinit();
                _ = destination.accounts.remove(id);
            }

            // Move the service to the destination
            // Note: We're transferring ownership of the ServiceAccount to the destination
            try destination.accounts.put(id, entry.value_ptr.*);
        }

        // Clear our tracking (without deinit-ing the services that were moved)
        self.modified_services.clearRetainingCapacity();
        self.deleted_services.clearRetainingCapacity();
    }

    /// Create a new DeltaSnapshot from this DeltaSnapshot (used for checkpoints)
    pub fn checkpoint(self: *const DeltaSnapshot) !DeltaSnapshot {
        var result = DeltaSnapshot.init(self.original);
        errdefer result.deinit();

        // Copy all modified services
        var modified_it = self.modified_services.iterator();
        while (modified_it.next()) |entry| {
            const id = entry.key_ptr.*;
            const account = entry.value_ptr;

            // Add to result's modified services
            try result.modified_services.put(id, try account.deepClone(self.allocator));
        }

        // Copy all deleted services
        var deleted_it = self.deleted_services.keyIterator();
        while (deleted_it.next()) |id| {
            try result.deleted_services.put(id.*, {});
        }

        return result;
    }

    /// Alias for checkpoint
    pub const deepClone = checkpoint;
};

test "DeltaSnapshot basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create original Delta
    var original = Delta.init(allocator);
    defer original.deinit();

    // Create a service in the original Delta
    const original_id: ServiceId = 1;
    const original_account = try original.getOrCreateAccount(original_id);
    original_account.balance = 1000;

    // Create a snapshot
    var snapshot = DeltaSnapshot.init(&original);
    defer snapshot.deinit();

    // Read a service from the snapshot (should read from original)
    const readonly_account = snapshot.getReadOnly(original_id);
    try testing.expect(readonly_account != null);
    try testing.expectEqual(readonly_account.?.balance, 1000);

    // Modify a service in the snapshot
    const mutable_account = try snapshot.getMutable(original_id);
    try testing.expect(mutable_account != null);
    mutable_account.?.balance = 2000;

    // Original should remain unchanged
    try testing.expectEqual(original_account.balance, 1000);

    // Snapshot should reflect the change
    const readonly_after_change = snapshot.getReadOnly(original_id);
    try testing.expect(readonly_after_change != null);
    try testing.expectEqual(readonly_after_change.?.balance, 2000);

    // Create a new service in the snapshot
    const new_id: ServiceId = 2;
    const new_account = try snapshot.createService(new_id);
    new_account.balance = 3000;

    // Mark a service for deletion
    _ = try snapshot.removeService(original_id);

    // Test service visibility after deletion
    try testing.expect(!snapshot.contains(original_id));
    try testing.expect(snapshot.contains(new_id));

    // Verify changes are being tracked
    try testing.expect(snapshot.hasChanges());

    // Commit changes back to the original Delta
    try snapshot.commit();

    // Check that the changes were applied
    try testing.expect(!original.accounts.contains(original_id));

    const committed_account = original.getAccount(new_id);
    try testing.expect(committed_account != null);
    try testing.expectEqual(committed_account.?.balance, 3000);

    // Snapshot should be empty after commit
    try testing.expect(!snapshot.hasChanges());
}

test "DeltaSnapshot checkpoint functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create original Delta
    var original = Delta.init(allocator);
    defer original.deinit();

    // Create a service in the original Delta
    const service_id: ServiceId = 1;
    var account = try original.getOrCreateAccount(service_id);
    account.balance = 1000;

    // Create a snapshot
    var snapshot = DeltaSnapshot.init(&original);
    defer snapshot.deinit();

    // Make a change to the snapshot
    var mutable_account = (try snapshot.getMutable(service_id)).?;
    mutable_account.balance = 2000;

    // Create a checkpoint
    var checkpoint_snapshot = try snapshot.checkpoint();
    defer checkpoint_snapshot.deinit();

    // Make more changes to the checkpoint
    mutable_account = (try checkpoint_snapshot.getMutable(service_id)).?;
    mutable_account.balance = 3000;

    // Original snapshot should still show 2000
    const original_snapshot_account = snapshot.getReadOnly(service_id).?;
    try testing.expectEqual(original_snapshot_account.balance, 2000);

    // Checkpoint snapshot should show 3000
    const checkpoint_account = checkpoint_snapshot.getReadOnly(service_id).?;
    try testing.expectEqual(checkpoint_account.balance, 3000);

    // Original should still show 1000
    try testing.expectEqual(account.balance, 1000);
}
