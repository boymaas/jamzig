
const std = @import("std");
const services = @import("services.zig");

const Delta = services.Delta;
const ServiceAccount = services.ServiceAccount;
const ServiceId = services.ServiceId;
const Allocator = std.mem.Allocator;

const trace = @import("tracing").scoped(.delta_snapshot);

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
        const span = trace.span(@src(), .init);
        defer span.deinit();
        span.debug("Initializing DeltaSnapshot from original Delta", .{});

        const result = DeltaSnapshot{
            .original = original,
            .modified_services = std.AutoHashMap(ServiceId, ServiceAccount).init(original.allocator),
            .deleted_services = std.AutoHashMap(ServiceId, void).init(original.allocator),
            .allocator = original.allocator,
        };

        span.debug("DeltaSnapshot initialized successfully", .{});
        return result;
    }

    /// Free all resources used by the snapshot
    pub fn deinit(self: *DeltaSnapshot) void {
        const span = trace.span(@src(), .deinit);
        defer span.deinit();
        span.debug("Deinitializing DeltaSnapshot", .{});
        span.trace("Modified services count: {d}", .{self.modified_services.count()});
        span.trace("Deleted services count: {d}", .{self.deleted_services.count()});

        var it = self.modified_services.iterator();
        while (it.next()) |entry| {
            span.trace("Deinitializing modified service ID: {d}", .{entry.key_ptr.*});
            entry.value_ptr.deinit();
        }
        self.modified_services.deinit();

        self.deleted_services.deinit();

        self.* = undefined;
        span.debug("DeltaSnapshot deinitialized", .{});
    }

    /// Get a read-only reference to a service
    /// Returns null if the service doesn't exist or has been deleted
    pub fn getReadOnly(self: *const DeltaSnapshot, id: ServiceId) ?*const ServiceAccount {
        const span = trace.span(@src(), .get_read_only);
        defer span.deinit();
        span.debug("Getting read-only reference for service ID: {d}", .{id});

        if (self.deleted_services.contains(id)) {
            span.debug("Service marked for deletion, returning null", .{});
            return null;
        }

        if (self.modified_services.getPtr(id)) |account| {
            span.debug("Found in modified services", .{});
            span.trace("Account balance: {d}", .{account.balance});
            return account;
        }

        const result = if (self.original.getAccount(id)) |account| account else null;
        if (result) |account| {
            span.debug("Found in original Delta", .{});
            span.trace("Account balance: {d}", .{account.balance});
        } else {
            span.debug("Service not found", .{});
        }

        return result;
    }

    /// Check if a service exists in this snapshot
    pub fn contains(self: *const DeltaSnapshot, id: ServiceId) bool {
        const span = trace.span(@src(), .contains);
        defer span.deinit();
        span.debug("Checking if service ID: {d} exists", .{id});

        if (self.deleted_services.contains(id)) {
            span.debug("Service is marked for deletion, returning false", .{});
            return false;
        }

        const result = self.modified_services.contains(id) or
            self.original.accounts.contains(id);

        span.debug("Service exists: {}", .{result});
        return result;
    }

    /// Get a mutable reference to a service
    /// This will create a copy of the service if it exists in the original state
    /// Returns null if the service doesn't exist
    pub fn getMutable(self: *DeltaSnapshot, id: ServiceId) !?*ServiceAccount {
        const span = trace.span(@src(), .get_mutable);
        defer span.deinit();
        span.debug("Getting mutable reference for service ID: {d}", .{id});

        if (self.deleted_services.contains(id)) {
            span.debug("Service marked for deletion, returning null", .{});
            return null;
        }

        if (self.modified_services.getPtr(id)) |account| {
            span.debug("Found in modified services", .{});
            span.trace("Account balance: {d}", .{account.balance});
            return account;
        }

        if (self.original.getAccount(id)) |account| {
            const clone_span = span.child(@src(), .clone_service);
            defer clone_span.deinit();

            clone_span.debug("Creating copy from original state", .{});
            var cloned = try account.deepClone(self.allocator);
            errdefer cloned.deinit();

            clone_span.trace("Original balance: {d}, cloned balance: {d}", .{ account.balance, cloned.balance });

            try self.modified_services.put(id, cloned);
            clone_span.debug("Added to modified services", .{});

            return self.modified_services.getPtr(id).?;
        }

        span.debug("Service not found", .{});
        return null;
    }

    /// Create a new service in this snapshot
    pub fn createService(self: *DeltaSnapshot, id: ServiceId) !*ServiceAccount {
        const span = trace.span(@src(), .create_service);
        defer span.deinit();
        span.debug("Creating new service with ID: {d}", .{id});

        if (self.contains(id)) {
            span.err("Service already exists", .{});
            return error.ServiceAlreadyExists;
        }

        if (self.deleted_services.remove(id)) {
            span.debug("Removed from deleted services", .{});
        }

        var new_account = ServiceAccount.init(self.allocator);
        errdefer new_account.deinit();
        span.debug("Initialized new service account", .{});

        try self.modified_services.put(id, new_account);
        span.debug("Added to modified services", .{});

        return self.modified_services.getPtr(id).?;
    }

    /// Mark a service for deletion
    pub fn removeService(self: *DeltaSnapshot, id: ServiceId) !bool {
        const span = trace.span(@src(), .remove_service);
        defer span.deinit();
        span.debug("Marking service for deletion, ID: {d}", .{id});

        if (!self.contains(id)) {
            span.debug("Service does not exist, nothing to remove", .{});
            return false;
        }

        if (self.modified_services.fetchRemove(id)) |entry| {
            span.debug("Removing from modified services", .{});
            @constCast(&entry.value).deinit();
        }

        try self.deleted_services.put(id, {});
        span.debug("Service marked for deletion", .{});
        return true;
    }

    /// Get the set of all service IDs that have been modified or deleted
    pub fn getChangedServiceIds(self: *const DeltaSnapshot) ![]ServiceId {
        const span = trace.span(@src(), .get_changed_service_ids);
        defer span.deinit();
        span.debug("Getting list of changed service IDs", .{});

        const total_changes = self.modified_services.count() + self.deleted_services.count();
        span.trace("Total changes: {d} (modified: {d}, deleted: {d})", .{ total_changes, self.modified_services.count(), self.deleted_services.count() });

        var result = try self.allocator.alloc(ServiceId, total_changes);
        errdefer self.allocator.free(result);

        var index: usize = 0;

        var modified_it = self.modified_services.keyIterator();
        while (modified_it.next()) |id| {
            result[index] = id.*;
            span.trace("Added modified service ID: {d}", .{id.*});
            index += 1;
        }

        var deleted_it = self.deleted_services.keyIterator();
        while (deleted_it.next()) |id| {
            result[index] = id.*;
            span.trace("Added deleted service ID: {d}", .{id.*});
            index += 1;
        }

        span.debug("Returning {d} changed service IDs", .{total_changes});
        return result;
    }

    /// Check if the snapshot has any changes
    pub fn hasChanges(self: *const DeltaSnapshot) bool {
        const span = trace.span(@src(), .has_changes);
        defer span.deinit();

        const has_modified = self.modified_services.count() > 0;
        const has_deleted = self.deleted_services.count() > 0;
        const result = has_modified or has_deleted;

        span.debug("Checking for changes: {}", .{result});
        span.trace("Modified count: {d}, deleted count: {d}", .{ self.modified_services.count(), self.deleted_services.count() });

        return result;
    }

    /// Apply all changes from this snapshot to the destination Delta
    pub fn commit(self: *DeltaSnapshot) !void {
        const span = trace.span(@src(), .commit);
        defer span.deinit();
        span.debug("Committing changes to original Delta", .{});
        span.trace("Modified services: {d}, deleted services: {d}", .{ self.modified_services.count(), self.deleted_services.count() });

        var destination: *Delta = @constCast(self.original);

        {
            const delete_span = span.child(@src(), .handle_deletions);
            defer delete_span.deinit();
            delete_span.debug("Processing {d} service deletions", .{self.deleted_services.count()});

            var deleted_it = self.deleted_services.keyIterator();
            while (deleted_it.next()) |id| {
                delete_span.trace("Removing service ID: {d}", .{id.*});
                if (destination.accounts.fetchRemove(id.*)) |entry| {
                    delete_span.trace("Service found and removed", .{});
                    @constCast(&entry.value).deinit();
                } else {
                    delete_span.trace("Service not found in destination", .{});
                }
            }
        }

        {
            const modify_span = span.child(@src(), .handle_modifications);
            defer modify_span.deinit();
            modify_span.debug("Processing {d} service modifications", .{self.modified_services.count()});

            var modified_it = self.modified_services.iterator();
            while (modified_it.next()) |modified_entry| {
                const id = modified_entry.key_ptr.*;
                modify_span.trace("Applying changes for service ID: {d}", .{id});

                if (destination.accounts.fetchRemove(id)) |removed| {
                    modify_span.trace("Removing existing service from destination", .{});
                    @constCast(&removed.value).deinit();
                } else {
                    modify_span.trace("Not yet in destination, creating", .{});
                }

                // TODO: when error occurs here, we have this value both in destination
                modify_span.trace("Adding modified service to destination", .{});
                try destination.accounts.put(id, modified_entry.value_ptr.*);
            }
        }

        span.debug("Clearing tracking structures", .{});
        self.modified_services.clearRetainingCapacity();
        self.deleted_services.clearRetainingCapacity();

        span.debug("Commit completed successfully", .{});
    }

    /// Create a new DeltaSnapshot from this DeltaSnapshot (used for checkpoints)
    pub fn checkpoint(self: *const DeltaSnapshot) !DeltaSnapshot {
        const span = trace.span(@src(), .checkpoint);
        defer span.deinit();
        span.debug("Creating checkpoint from DeltaSnapshot", .{});

        var result = DeltaSnapshot.init(self.original);
        errdefer result.deinit();

        {
            const copy_span = span.child(@src(), .copy_modified);
            defer copy_span.deinit();
            copy_span.debug("Copying {d} modified services", .{self.modified_services.count()});

            var modified_it = self.modified_services.iterator();
            while (modified_it.next()) |entry| {
                const id = entry.key_ptr.*;
                const account = entry.value_ptr;

                copy_span.trace("Cloning service ID: {d}", .{id});

                try result.modified_services.put(id, try account.deepClone(self.allocator));
            }
        }

        {
            const copy_span = span.child(@src(), .copy_deleted);
            defer copy_span.deinit();
            copy_span.debug("Copying {d} deleted services", .{self.deleted_services.count()});

            var deleted_it = self.deleted_services.keyIterator();
            while (deleted_it.next()) |id| {
                copy_span.trace("Adding deleted service ID: {d}", .{id.*});
                try result.deleted_services.put(id.*, {});
            }
        }

        span.debug("Checkpoint created successfully", .{});
        return result;
    }

    /// Alias for checkpoint
    pub const deepClone = checkpoint;
};

test "DeltaSnapshot basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var original = Delta.init(allocator);
    defer original.deinit();

    const original_id: ServiceId = 1;
    const original_account = try original.getOrCreateAccount(original_id);
    original_account.balance = 1000;

    var snapshot = DeltaSnapshot.init(&original);
    defer snapshot.deinit();

    const readonly_account = snapshot.getReadOnly(original_id);
    try testing.expect(readonly_account != null);
    try testing.expectEqual(readonly_account.?.balance, 1000);

    const mutable_account = try snapshot.getMutable(original_id);
    try testing.expect(mutable_account != null);
    mutable_account.?.balance = 2000;

    try testing.expectEqual(original_account.balance, 1000);

    const readonly_after_change = snapshot.getReadOnly(original_id);
    try testing.expect(readonly_after_change != null);
    try testing.expectEqual(readonly_after_change.?.balance, 2000);

    const new_id: ServiceId = 2;
    const new_account = try snapshot.createService(new_id);
    new_account.balance = 3000;

    _ = try snapshot.removeService(original_id);

    try testing.expect(!snapshot.contains(original_id));
    try testing.expect(snapshot.contains(new_id));

    try testing.expect(snapshot.hasChanges());

    try snapshot.commit();

    try testing.expect(!original.accounts.contains(original_id));

    const committed_account = original.getAccount(new_id);
    try testing.expect(committed_account != null);
    try testing.expectEqual(committed_account.?.balance, 3000);

    try testing.expect(!snapshot.hasChanges());
}

test "DeltaSnapshot checkpoint functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var original = Delta.init(allocator);
    defer original.deinit();

    const service_id: ServiceId = 1;
    var account = try original.getOrCreateAccount(service_id);
    account.balance = 1000;

    var snapshot = DeltaSnapshot.init(&original);
    defer snapshot.deinit();

    var mutable_account = (try snapshot.getMutable(service_id)).?;
    mutable_account.balance = 2000;

    var checkpoint_snapshot = try snapshot.checkpoint();
    defer checkpoint_snapshot.deinit();

    mutable_account = (try checkpoint_snapshot.getMutable(service_id)).?;
    mutable_account.balance = 3000;

    const original_snapshot_account = snapshot.getReadOnly(service_id).?;
    try testing.expectEqual(original_snapshot_account.balance, 2000);

    const checkpoint_account = checkpoint_snapshot.getReadOnly(service_id).?;
    try testing.expectEqual(checkpoint_account.balance, 3000);

    try testing.expectEqual(account.balance, 1000);
}
