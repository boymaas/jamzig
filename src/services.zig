const std = @import("std");
const math = std.math;
const mem = std.mem;

const types = @import("types.zig");
const state_keys = @import("state_keys.zig");
const Params = @import("jam_params.zig").Params;

const Allocator = std.mem.Allocator;

const trace = @import("tracing").scoped(.service_state_keys);

pub const Transfer = struct {
    from: ServiceId,
    to: ServiceId,
    amount: Balance,
};

pub const Hash = types.OpaqueHash;
pub const ServiceId = types.ServiceId;
pub const Balance = types.Balance;
pub const GasLimit = types.Gas;
pub const Timeslot = types.TimeSlot;

// Gp@9.3
pub const StorageFootprint = struct {
    a_i: u32,
    a_o: u64,
    a_t: Balance,
};

/// Result of analyzing a potential storage write operation
/// Contains all necessary information to avoid duplicate lookups
pub const StorageWriteAnalysis = struct {
    new_footprint: StorageFootprint,
    storage_key: types.StateKey, // Already constructed key
    prior_value: ?[]const u8, // Existing value if any
    prior_value_length: u64, // Length or NONE constant for return value
};

pub const PreimageLookup = struct {
    // Timeslot updates for preimage submissions (up to three slots stored)
    // As per Section 9.2.2. Semantics, the historical status component h ∈ ⟦NT⟧:3
    // is a sequence of up to three time slots. The cardinality of this sequence
    // implies one of four modes:
    //
    // 1. h = []: The preimage is requested but not yet supplied.
    // 2. h ∈ ⟦NT⟧1: The preimage is available since time h[0].
    // 3. h ∈ ⟦NT⟧2: The preimage was available from h[0] until h[1], now unavailable.
    // 4. h ∈ ⟦NT⟧3: The preimage is available since h[2], was previously available
    status: [3]?Timeslot,

    pub fn asSlice(self: *const @This()) []const ?Timeslot {
        // Else we have an existing one, now set the appropiate
        // value based on the tailing count
        var non_null_len: usize = 0;
        for (self.status) |e| {
            if (e != null) {
                non_null_len += 1;
            } else break;
        }

        return self.status[0..non_null_len];
    }

    pub fn asSliceMut(self: *@This()) []?Timeslot {
        // Else we have an existing one, now set the appropiate
        // value based on the tailing count
        var non_null_len: usize = 0;
        for (self.status) |e| {
            if (e != null) {
                non_null_len += 1;
            } else break;
        }

        return self.status[0..non_null_len];
    }
};

pub const PreimageSubmission = struct {
    index: ServiceId,
    hash: Hash,
    preimage: []const u8,
};

pub const AccountUpdate = struct {
    index: ServiceId,
    new_balance: Balance,
    new_gas_limit: GasLimit,
};

/// See GP0.4.1p@Ch9
pub const ServiceAccount = struct {
    // Unified data container for ALL service data (storage, preimages, preimage lookups)
    // JAM v0.6.7: Keys are intentionally opaque - the merkle tree doesn't care about data types
    // All data is stored as 31-byte StateKeys mapped to byte arrays
    data: std.AutoHashMap(types.StateKey, []const u8),

    // Service information version (v0.7.1)
    version: u8,

    // Must be present in pre-image lookup, this in self.preimages
    code_hash: Hash,

    // The balance of the account, which is the amount of the native token held
    // by the account.
    balance: Balance,

    // The minumum gas limit before the accumulate and on transfer may be
    // executed
    min_gas_accumulate: GasLimit,
    min_gas_on_transfer: GasLimit,

    // Storage offset for gratis (free) storage allowance - NEW in v0.6.7
    storage_offset: u64,

    // Time slot when this service was created (r in spec)
    creation_slot: u32, // types.TimeSlot or u32

    // Time slot of the most recent accumulation for this service (a in spec)
    last_accumulation_slot: u32, // types.TimeSlot or u32

    // Index of the parent service that created this service (p in spec)
    parent_service: types.ServiceId, // or u32

    // Storage footprint tracking - NEW in v0.6.7
    // We directly track a_i and a_o as defined in the graypaper
    footprint_items: u32, // a_i = 2·|preimage_lookups| + |storage_items|
    footprint_bytes: u64, // a_o = Σ(81 + length) for lookups + Σ(65 + |value|) for storage

    pub fn init(allocator: Allocator) ServiceAccount {
        return .{
            .data = std.AutoHashMap(types.StateKey, []const u8).init(allocator),
            .version = 0,
            .code_hash = undefined,
            .balance = 0,
            .min_gas_accumulate = 0,
            .min_gas_on_transfer = 0,
            .storage_offset = 0,
            .creation_slot = 0,
            .last_accumulation_slot = 0,
            .parent_service = 0,
            .footprint_items = 0,
            .footprint_bytes = 0,
        };
    }

    pub fn deepClone(self: *const ServiceAccount, allocator: Allocator) !ServiceAccount {
        var clone = ServiceAccount.init(allocator);
        errdefer clone.deinit();

        // Clone unified data map
        var data_it = self.data.iterator();
        while (data_it.next()) |entry| {
            const cloned_value = try allocator.dupe(u8, entry.value_ptr.*);
            try clone.data.put(entry.key_ptr.*, cloned_value);
        }

        // Copy all fields including tracking fields - they represent the exact same data
        clone.version = self.version;
        clone.code_hash = self.code_hash;
        clone.balance = self.balance;
        clone.min_gas_accumulate = self.min_gas_accumulate;
        clone.min_gas_on_transfer = self.min_gas_on_transfer;
        clone.storage_offset = self.storage_offset;
        clone.creation_slot = self.creation_slot;
        clone.last_accumulation_slot = self.last_accumulation_slot;
        clone.parent_service = self.parent_service;
        clone.footprint_items = self.footprint_items;
        clone.footprint_bytes = self.footprint_bytes;

        return clone;
    }

    pub fn deinit(self: *ServiceAccount) void {
        var data_it = self.data.valueIterator();
        while (data_it.next()) |value| {
            self.data.allocator.free(value.*);
        }
        self.data.deinit();
        self.* = undefined;
    }

    // Functionality to read and write storage, reflecting access patterns in Section 4.9.2 on Service State.
    pub fn readStorage(self: *const ServiceAccount, service_id: u32, key: []const u8) ?[]const u8 {
        const storage_key = state_keys.constructStorageKey(service_id, key);
        const value = self.data.get(storage_key);

        const span = trace.span(@src(), .storage_read);
        defer span.deinit();
        span.debug("Storage READ - Service: {d}, Key: {s} ({d} bytes), StateKey: {s}, Found: {}", .{
            service_id,
            std.fmt.fmtSliceHexLower(key),
            key.len,
            &formatStateKey(storage_key),
            value != null,
        });

        if (value) |v| {
            span.trace("  Value: {}", .{formatValue(v)});
        }

        return value;
    }

    pub fn resetStorage(self: *ServiceAccount, service_id: u32, key: []const u8) void {
        const storage_key = state_keys.constructStorageKey(service_id, key);

        const span = trace.span(@src(), .storage_reset);
        defer span.deinit();

        if (self.data.getPtr(storage_key)) |old_value_ptr| {
            span.debug("Storage RESET - Service: {d}, Key: {s} ({d} bytes), StateKey: {s}, Prior: {d} bytes", .{
                service_id,
                std.fmt.fmtSliceHexLower(key),
                key.len,
                &formatStateKey(storage_key),
                old_value_ptr.len,
            });

            // Update a_o - reduce bytes by old value length (key overhead stays)
            self.footprint_bytes = self.footprint_bytes - old_value_ptr.len;

            self.data.allocator.free(old_value_ptr.*);
            self.data.put(storage_key, &[_]u8{}) catch unreachable;
            // Empty value doesn't add bytes
        } else {
            span.debug("Storage RESET - Service: {d}, Key: {s} ({d} bytes), StateKey: {s}, Not found", .{
                service_id,
                std.fmt.fmtSliceHexLower(key),
                key.len,
                &formatStateKey(storage_key),
            });
        }
    }

    // Returns the length of the removed value
    pub fn removeStorage(self: *ServiceAccount, service_id: u32, key: []const u8) ?usize {
        const storage_key = state_keys.constructStorageKey(service_id, key);

        const span = trace.span(@src(), .storage_remove);
        defer span.deinit();

        if (self.data.fetchRemove(storage_key)) |entry| {
            const value_length = entry.value.len;

            span.debug("Storage REMOVE - Service: {d}, Key: {s} ({d} bytes), StateKey: {s}, Removed: {d} bytes", .{
                service_id,
                std.fmt.fmtSliceHexLower(key),
                key.len,
                &formatStateKey(storage_key),
                value_length,
            });

            // In trace mode, show what was removed
            span.trace("  Removed value: {}", .{formatValue(entry.value)});

            // Update a_i and a_o for storage removal
            self.footprint_items -= 1; // One storage item removed
            self.footprint_bytes -= 34 + key.len + value_length; // 34 + key length + value length

            self.data.allocator.free(entry.value);
            return value_length;
        }

        span.debug("Storage REMOVE - Service: {d}, Key: {s} ({d} bytes), StateKey: {s}, Not found", .{
            service_id,
            std.fmt.fmtSliceHexLower(key),
            key.len,
            &formatStateKey(storage_key),
        });

        return null; // Key not found
    }

    pub fn writeStorage(self: *ServiceAccount, service_id: u32, key: []const u8, value: []const u8) !?[]const u8 {
        const storage_key = state_keys.constructStorageKey(service_id, key);
        // Clear the old, otherwise we are leaking
        const old_value = self.data.get(storage_key);

        const span = trace.span(@src(), .storage_write);
        defer span.deinit();
        span.debug("Storage WRITE - Service: {d}, Key: {s} ({d} bytes), StateKey: {s}, Value: {d} bytes, Prior: {d} bytes", .{
            service_id,
            std.fmt.fmtSliceHexLower(key),
            key.len,
            &formatStateKey(storage_key),
            value.len,
            if (old_value) |old| old.len else 0,
        });

        // In trace mode, show the full value being written (up to 512 bytes)
        span.trace("  Value: {}", .{formatValue(value)});
        if (old_value) |old| {
            span.trace("  Prior: {}", .{formatValue(old)});
        }

        // Update a_i and a_o based on whether this is new or update
        if (old_value) |old| {
            // Updating existing entry - only a_o changes (value size difference)
            self.footprint_bytes = self.footprint_bytes - old.len + value.len;
        } else {
            // New entry - increment both a_i and a_o
            self.footprint_items += 1; // One new storage item
            self.footprint_bytes += 34 + key.len + value.len; // 34 + key length + value length
        }

        try self.data.put(storage_key, value);

        return old_value;
    }

    pub fn writeStorageNoFootprint(self: *ServiceAccount, service_id: u32, key: []const u8, value: []const u8) !void {
        // This function does not update footprint metrics
        const storage_key = state_keys.constructStorageKey(service_id, key);
        try self.data.put(storage_key, value);
    }

    pub fn writeStorageFreeOldValue(self: *ServiceAccount, service_id: u32, key: []const u8, value: []const u8) !void {
        const maybe_old_value = try self.writeStorage(service_id, key, value);
        if (maybe_old_value) |old_value| self.data.allocator.free(old_value);
    }

    // Functions to add and manage preimages correspond to the discussion in Section 4.9.2 and Appendix D.
    pub fn dupeAndAddPreimage(self: *ServiceAccount, key: types.StateKey, preimage: []const u8) !void {
        const new_preimage = try self.data.allocator.dupe(u8, preimage);

        const span = trace.span(@src(), .preimage_add);
        defer span.deinit();
        span.debug("Preimage ADD - StateKey: {s}, Size: {d} bytes", .{
            &formatStateKey(key),
            preimage.len,
        });

        // In trace mode, show the preimage (up to 512 bytes)
        span.trace("  Preimage: {}", .{formatValue(preimage)});

        // Preimages do NOT affect a_i or a_o according to the graypaper
        // They are stored separately and don't contribute to storage footprint

        try self.data.put(key, new_preimage);
    }

    pub fn getPreimage(self: *const ServiceAccount, key: types.StateKey) ?[]const u8 {
        const value = self.data.get(key);

        const span = trace.span(@src(), .preimage_get);
        defer span.deinit();
        span.debug("Preimage GET - StateKey: {s}, Found: {}", .{
            &formatStateKey(key),
            value != null,
        });

        if (value) |v| {
            span.trace("  Preimage: {}", .{formatValue(v)});
        }

        return value;
    }

    pub fn hasPreimage(self: *const ServiceAccount, key: types.StateKey) bool {
        return self.data.contains(key);
    }

    // Helper function to encode PreimageLookup to bytes for storage
    pub fn encodePreimageLookup(allocator: Allocator, lookup: PreimageLookup) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        // Count non-null timestamps
        var count: u8 = 0;
        for (lookup.status) |ts| {
            if (ts != null) count += 1 else break;
        }

        // Write count as single byte
        try buffer.append(count);

        // Write each timestamp as 4 bytes little-endian
        for (0..count) |i| {
            try buffer.writer().writeInt(u32, lookup.status[i].?, .little);
        }

        return buffer.toOwnedSlice();
    }

    // Helper function to decode PreimageLookup from bytes
    fn decodePreimageLookup(data: []const u8) !PreimageLookup {
        if (data.len < 1) return error.InvalidData;

        const count = data[0];
        if (count > 3) return error.InvalidData;
        if (data.len != 1 + count * 4) return error.InvalidData;

        var lookup = PreimageLookup{ .status = .{ null, null, null } };

        for (0..count) |i| {
            const offset = 1 + i * 4;
            lookup.status[i] = std.mem.readInt(u32, data[offset..][0..4], .little);
        }

        return lookup;
    }

    //  PreImageLookups assume correct state, that is when you sollicit a
    //  preimage. It should not be available already.
    pub fn getPreimageLookup(self: *const ServiceAccount, service_id: u32, hash: Hash, length: u32) ?PreimageLookup {
        const key = state_keys.constructServicePreimageLookupKey(service_id, length, hash);
        const data = self.data.get(key);

        const span = trace.span(@src(), .preimage_lookup);
        defer span.deinit();
        span.debug("Preimage LOOKUP - Service: {d}, Hash: {s}, Length: {d}, StateKey: {s}, Found: {}", .{
            service_id,
            std.fmt.fmtSliceHexLower(&hash),
            length,
            &formatStateKey(key),
            data != null,
        });

        if (data == null) return null;
        return decodePreimageLookup(data.?) catch null;
    }

    /// Created an entry in preimages_lookups indicating we need a preimage
    pub fn solicitPreimage(
        self: *ServiceAccount,
        service_id: u32,
        hash: Hash,
        length: u32,
        current_timeslot: types.TimeSlot,
    ) !void {

        // TODO: refactor this and make this state keys usage toward storage consistent.
        const key = state_keys.constructServicePreimageLookupKey(service_id, length, hash);

        const span = trace.span(@src(), .preimage_solicit);
        defer span.deinit();
        span.debug("Preimage SOLICIT - Service: {d}, Hash: {s}, Length: {d}, StateKey: {s}, Slot: {d}", .{
            service_id,
            std.fmt.fmtSliceHexLower(&hash),
            length,
            &formatStateKey(key),
            current_timeslot,
        });

        // Check if we already have an entry for this hash/length
        if (self.data.get(key)) |existing_data| {
            var preimage_lookup = try decodePreimageLookup(existing_data);
            const pi = preimage_lookup.asSlice();

            // Validate status transitions per graypaper
            switch (pi.len) {
                0 => {
                    span.warn("Action: Already pending, cannot re-solicit", .{});
                    // Status [] - Already pending, can't re-solicit
                    return error.AlreadySolicited;
                },
                1 => {
                    span.warn("Action: Already available, no need to sollicit", .{});
                    // Status [x] - Already available, no need to solicit
                    return error.AlreadyAvailable;
                },
                2 => {
                    span.debug("Action: Valid resollicitation after unavailable period", .{});
                    // Status [x,y] - Valid re-solicitation after unavailable period
                    // Transition: [x,y] → [x,y,t]
                    preimage_lookup.status[2] = current_timeslot;
                    // Re-encode and store
                    const encoded = try encodePreimageLookup(self.data.allocator, preimage_lookup);
                    self.data.allocator.free(existing_data);
                    try self.data.put(key, encoded);
                    return;
                },
                3 => {
                    span.warn("Action: Already Resolicited", .{});
                    // Status [x,y,z] - Already re-solicited, can't re-solicit again
                    return error.AlreadyReSolicited;
                },
                else => {
                    // Invalid status length
                    span.err("Action: Invalid state", .{});
                    return error.InvalidState;
                },
            }
        } else {
            span.trace("Action: Creating new lookup with empty status", .{});
            // If no lookup exists yet, create a new one with an empty status
            const new_lookup = PreimageLookup{
                .status = .{ null, null, null },
            };
            const encoded = try encodePreimageLookup(self.data.allocator, new_lookup);
            // Track new preimage lookup in a_i and a_o
            self.footprint_items += 2; // Each lookup adds 2 to a_i
            self.footprint_bytes += 81 + length; // 81 base + length to a_o
            try self.data.put(key, encoded);
        }
    }

    /// Forgets a preimage
    pub fn forgetPreimage(
        self: *ServiceAccount,
        service_id: u32,
        hash: Hash,
        length: u32,
        current_slot: types.TimeSlot,
        preimage_expungement_period: u32,
    ) !void {
        // we can remove the entries when timeout occurred
        const lookup_key = state_keys.constructServicePreimageLookupKey(service_id, length, hash);

        const span = trace.span(@src(), .preimage_forget);
        defer span.deinit();
        span.debug("Preimage FORGET - Service: {d}, Hash: {s}, Length: {d}, StateKey: {s}, Slot: {d}", .{
            service_id,
            std.fmt.fmtSliceHexLower(&hash),
            length,
            &formatStateKey(lookup_key),
            current_slot,
        });

        if (self.data.get(lookup_key)) |existing_data| {
            var preimage_lookup = try decodePreimageLookup(existing_data);
            var pi = preimage_lookup.asSliceMut();
            if (pi.len == 0) {
                span.trace("  Action: Removing empty lookup and preimage", .{});
                self.data.allocator.free(existing_data);
                _ = self.data.remove(lookup_key);
                self.footprint_items -= 2; // Each lookup removal subtracts 2 from a_i
                self.footprint_bytes -= 81 + length; // Subtract from a_o
                self.removePreimageByHash(service_id, hash);
            } else if (pi.len == 1) {
                span.trace("  Action: Marking preimage as unavailable [{?}] -> [{?}, {?}]", .{ pi[0], pi[0], current_slot });
                preimage_lookup.status[1] = current_slot; // [x, t]
                // Re-encode and store
                const encoded = try encodePreimageLookup(self.data.allocator, preimage_lookup);
                self.data.allocator.free(existing_data);
                try self.data.put(lookup_key, encoded);
            } else if (pi.len == 2 and pi[1].? < current_slot -| preimage_expungement_period) {
                span.trace("  Action: Expunging expired preimage [{?}, {?}]", .{ pi[0], pi[1] });
                self.data.allocator.free(existing_data);
                _ = self.data.remove(lookup_key);
                self.footprint_items -= 2; // Each lookup removal subtracts 2 from a_i
                self.footprint_bytes -= 81 + length; // Subtract from a_o
                self.removePreimageByHash(service_id, hash);
            } else if (pi.len == 3 and pi[1].? < current_slot -| preimage_expungement_period) {
                span.trace("  Action: Re-marking as unavailable [{?}, {?}, {?}] -> [{?}, {?}]", .{ pi[0], pi[1], pi[2], pi[2], current_slot });
                // [x,y,w]
                pi[0] = pi[2];
                pi[1] = current_slot;
                pi[2] = null;
                // Re-encode and store
                const encoded = try encodePreimageLookup(self.data.allocator, preimage_lookup);
                self.data.allocator.free(existing_data);
                try self.data.put(lookup_key, encoded);
            } else {
                span.trace("  Action: No action taken - incorrect state or not expired", .{});
                // TODO: check this against GP
                return error.IncorrectPreimageLookupState;
            }
        } else {
            span.debug("  Lookup not found", .{});
            return error.PreimageLookupKeyMissing;
        }
    }

    /// Internal helper to remove preimage by hash
    fn removePreimageByHash(self: *ServiceAccount, service_id: u32, target_hash: Hash) void {
        // Create the structured preimage key directly
        const preimage_key = state_keys.constructServicePreimageKey(service_id, target_hash);

        if (self.data.fetchRemove(preimage_key)) |removed| {
            // Preimages do NOT affect a_i or a_o
            self.data.allocator.free(removed.value);
        }
    }

    // method to determine if this service needs a preimage
    pub fn needsPreImage(self: *const ServiceAccount, service_id: u32, hash: Hash, length: u32, current_timeslot: Timeslot) bool {
        // Check if we have an entry in preimage_lookups
        const key = state_keys.constructServicePreimageLookupKey(service_id, length, hash);

        if (self.data.get(key)) |data| {
            const lookup = decodePreimageLookup(data) catch return false;
            const status = lookup.asSlice();

            // Case 1: Empty status - never supplied after solicitation
            if (status.len == 0) {
                return true;
            }

            // Case 2: One-element status [t1, null, null] - available since t1
            if (status.len == 1) {
                return false; // Already available
            }

            // Case 3: Two-element status [t1, t2, null] - was available but now unavailable
            if (status.len == 2) {
                return current_timeslot >= status[1].?; // Needed if current time is past unavailability time
            }

            // Case 4: Three-element status [t1, t2, t3] - available again since t3
            if (status.len == 3) {
                return false; // Already available again
            }
        }

        // No lookup entry for this hash/length
        return false;
    }

    // method to always set the pre-image lookup value
    pub fn registerPreimageAvailable(
        self: *ServiceAccount,
        service_id: u32,
        hash: Hash,
        length: u32,
        timeslot: ?Timeslot,
    ) !void {
        const key = state_keys.constructServicePreimageLookupKey(service_id, length, hash);

        const span = trace.span(@src(), .preimage_register);
        defer span.deinit();
        span.debug("Preimage REGISTER - Service: {d}, Hash: {s}, Length: {d}, StateKey: {s}, Slot: {?}", .{
            service_id,
            std.fmt.fmtSliceHexLower(&hash),
            length,
            &formatStateKey(key),
            timeslot,
        });

        // If we do not have one, easy just set first on and ready
        const existing_data = self.data.get(key) orelse {
            span.trace("  Action: Creating new lookup with slot [{?}]", .{timeslot});
            // If no lookup exists yet, create a new one with timeslot as the first entry
            const new_lookup = PreimageLookup{
                .status = .{ timeslot, null, null },
            };
            const encoded = try encodePreimageLookup(self.data.allocator, new_lookup);
            try self.data.put(key, encoded);
            self.footprint_items += 2; // Each lookup adds 2 to a_i
            self.footprint_bytes += 81 + length; // 81 base + length to a_o
            return;
        };

        const existing_lookup = try decodePreimageLookup(existing_data);
        const status = existing_lookup.asSlice();

        // Create a modified lookup based on the existing one
        var updated_lookup = existing_lookup;

        // Update the status based on the current state:
        // - If all slots are null, set the first slot
        // - If first slot is set but second is and third null, set update te first slot
        // - If first and second slots are set, set the third slot (marking available again)
        if (status.len <= 1) {
            span.trace("  Action: Updating lookup [{?}] -> [{?}]", .{ if (status.len > 0) status[0] else null, timeslot });
            updated_lookup.status[0] = timeslot;
        } else if (status.len >= 2) {
            span.trace("  Action: Marking available again [{?}, {?}] -> [{?}, {?}, {?}]", .{ status[0], status[1], status[0], status[1], timeslot });
            updated_lookup.status[2] = timeslot;
        }

        const encoded = try encodePreimageLookup(self.data.allocator, updated_lookup);
        self.data.allocator.free(existing_data);
        try self.data.put(key, encoded);
    }

    /// Same as registerPreimageAvailable but does NOT update footprint values.
    /// Used when loading test vectors where footprint is already accounted for.
    /// Sets the preimage to "provided" state (status[0] and status[1] both set).
    pub fn registerPreimageAvailableNoFootprint(
        self: *ServiceAccount,
        service_id: u32,
        hash: Hash,
        length: u32,
        timeslot: ?Timeslot,
    ) !void {
        const key = state_keys.constructServicePreimageLookupKey(service_id, length, hash);

        // If we do not have one, create a new lookup
        const existing_data = self.data.get(key) orelse {
            // For test vectors, set both status[0] and status[1] to mark as "provided"
            // This makes the preimage ejectable (status.len == 2)
            const new_lookup = PreimageLookup{
                .status = .{ timeslot, timeslot, null },
            };
            const encoded = try encodePreimageLookup(self.data.allocator, new_lookup);
            try self.data.put(key, encoded);
            // Note: NOT updating footprint - caller has already set it
            return;
        };

        const existing_lookup = try decodePreimageLookup(existing_data);
        const status = existing_lookup.asSlice();

        var updated_lookup = existing_lookup;

        if (status.len <= 1) {
            updated_lookup.status[0] = timeslot;
            updated_lookup.status[1] = timeslot;
        } else if (status.len >= 2) {
            updated_lookup.status[2] = timeslot;
        }

        const encoded = try encodePreimageLookup(self.data.allocator, updated_lookup);
        self.data.allocator.free(existing_data);
        try self.data.put(key, encoded);
    }

    // 9.2.2 Implement the historical lookup function
    pub fn historicalLookup(self: *ServiceAccount, service_id: u32, time: Timeslot, hash: Hash) ?[]const u8 {
        // Create the structured preimage key
        const preimage_key = state_keys.constructServicePreimageKey(service_id, hash);

        // first get the preimage, if not return null
        if (self.getPreimage(preimage_key)) |preimage| {
            // see if we have it in the lookup table
            const lookup_key = state_keys.constructServicePreimageLookupKey(service_id, @intCast(preimage.len), hash);
            if (self.data.get(lookup_key)) |lookup_data| {
                const lookup = decodePreimageLookup(lookup_data) catch return null;
                const status = lookup.status;
                if (status[0] == null) {
                    return null;
                } else if (status[1] == null) {
                    if (status[0].? <= time) {
                        return preimage;
                    } else {
                        return null;
                    }
                } else if (status[2] == null) {
                    if (status[0].? <= time and time < status[1].?) {
                        return preimage;
                    } else {
                        return null;
                    }
                } else {
                    if (status[0].? <= time and time < status[1].? or status[2].? <= time) {
                        return preimage;
                    } else {
                        return null;
                    }
                }
            }
        }
        return null;
    }

    pub fn setMinGasAccumulate(self: *ServiceAccount, new_limit: GasLimit) void {
        self.min_gas_accumulate = new_limit;
    }

    pub fn setMinGasOnTransfer(self: *ServiceAccount, new_min_limit: GasLimit) void {
        self.min_gas_on_transfer = new_min_limit;
    }

    /// Calculate storage footprint from tracked values
    /// Returns the footprint metrics including the threshold balance
    pub fn getStorageFootprint(self: *const ServiceAccount, params: Params) StorageFootprint {
        // We directly track a_i and a_o
        const a_i = self.footprint_items;
        const a_o = self.footprint_bytes;

        // Calculate threshold balance a_t
        // Per graypaper: a_t = max(0, B_S + B_I·a_i + B_L·a_o - a_f)
        // Where a_f is the storage_offset (free storage allowance)
        const base_cost = params.basic_service_balance + params.min_balance_per_item * a_i + params.min_balance_per_octet * a_o;

        // Subtract free storage allowance if set (a_f > 0), otherwise use base cost
        // storage_offset == 0 means no free storage, storage_offset > 0 means free storage granted
        const a_t: Balance = if (self.storage_offset > 0)
            base_cost -| self.storage_offset // Saturating subtraction ensures max(0, ...)
        else
            base_cost;

        return .{ .a_i = a_i, .a_o = a_o, .a_t = a_t };
    }

    /// Analyze a potential storage write operation
    /// Returns all necessary information to avoid duplicate lookups and key construction
    /// StorageWriteAnalysis does not own any data.
    pub fn analyzeStorageWrite(
        self: *const ServiceAccount,
        params: Params,
        service_id: u32,
        key: []const u8,
        new_value_len: usize,
    ) StorageWriteAnalysis {
        const storage_key = state_keys.constructStorageKey(service_id, key);
        const old_value = self.data.get(storage_key);

        // Calculate potential new a_i and a_o
        var new_a_i = self.footprint_items;
        var new_a_o = self.footprint_bytes;

        if (old_value) |old| {
            // Updating existing entry - only a_o changes (value size difference)
            new_a_o = new_a_o - old.len + new_value_len;
        } else {
            // New entry - increment both a_i and a_o
            new_a_i += 1; // One new storage item
            new_a_o += 34 + key.len + new_value_len; // 34 + key length + value length
        }

        // Calculate threshold balance with potential new values
        // Per graypaper: a_t = max(0, B_S + B_I·a_i + B_L·a_o - a_f)
        const base_cost = params.basic_service_balance + params.min_balance_per_item * new_a_i + params.min_balance_per_octet * new_a_o;
        const new_a_t: Balance = if (self.storage_offset > 0)
            base_cost -| self.storage_offset // Saturating subtraction ensures max(0, ...)
        else
            base_cost;

        // Use NONE constant (2^64 - 1) when no prior value exists
        const NONE = std.math.maxInt(u64) - 0; // ReturnCode.NONE value
        const prior_value_length: u64 = if (old_value) |old| old.len else NONE;

        return .{
            .new_footprint = .{ .a_i = new_a_i, .a_o = new_a_o, .a_t = new_a_t },
            .storage_key = storage_key,
            .prior_value = old_value,
            .prior_value_length = prior_value_length,
        };
    }

    /// Calculate what the storage footprint WOULD BE after a write operation
    /// Does not modify state, only calculates the potential new footprint
    /// (Kept for backward compatibility, but analyzeStorageWrite is preferred)
    pub fn calculateStorageFootprintAfterWrite(
        self: *const ServiceAccount,
        params: Params,
        service_id: u32,
        key: []const u8,
        new_value_len: usize,
    ) StorageFootprint {
        const analysis = self.analyzeStorageWrite(params, service_id, key, new_value_len);
        return analysis.new_footprint;
    }

    /// Calculate what the storage footprint WOULD BE after a removal
    /// Returns null if key doesn't exist (can't remove non-existent key)
    pub fn calculateStorageFootprintAfterRemoval(
        self: *const ServiceAccount,
        params: Params,
        service_id: u32,
        key: []const u8,
    ) ?StorageFootprint {
        const storage_key = state_keys.constructStorageKey(service_id, key);
        const old_value = self.data.get(storage_key) orelse return null;

        // Calculate potential new a_i and a_o after removal
        const new_a_i = self.footprint_items - 1; // One storage item removed
        const new_a_o = self.footprint_bytes - (34 + key.len + old_value.len); // 34 + key length + value length

        // Calculate threshold balance with potential new values
        // Per graypaper: a_t = max(0, B_S + B_I·a_i + B_L·a_o - a_f)
        const base_cost = params.basic_service_balance + params.min_balance_per_item * new_a_i + params.min_balance_per_octet * new_a_o;
        const new_a_t: Balance = if (self.storage_offset > 0)
            base_cost -| self.storage_offset // Saturating subtraction ensures max(0, ...)
        else
            base_cost;

        return .{ .a_i = new_a_i, .a_o = new_a_o, .a_t = new_a_t };
    }

    /// Check if a write operation would exceed balance
    /// Returns true if the operation is affordable, false otherwise
    pub fn canAffordStorageWrite(
        self: *const ServiceAccount,
        params: Params,
        service_id: u32,
        key: []const u8,
        new_value_len: usize,
    ) bool {
        const new_footprint = self.calculateStorageFootprintAfterWrite(params, service_id, key, new_value_len);
        return new_footprint.a_t <= self.balance;
    }

    /// Check if we can afford to remove a key
    /// Removal always reduces storage cost, so should always be affordable
    /// Returns false if key doesn't exist
    pub fn canAffordStorageRemoval(
        self: *const ServiceAccount,
        params: Params,
        service_id: u32,
        key: []const u8,
    ) bool {
        const new_footprint = self.calculateStorageFootprintAfterRemoval(params, service_id, key) orelse return false;
        // Removal reduces storage, so should always be affordable
        // But we check anyway for consistency
        return new_footprint.a_t <= self.balance;
    }
};

// `Delta` is the overarching structure that manages the state of the protocol
// and its various service accounts. As defined in GP0.4.1p@Ch9

pub const Delta = struct {
    accounts: std.AutoHashMap(ServiceId, ServiceAccount),
    allocator: Allocator,

    pub const Snapshot = @import("services_snapshot.zig").DeltaSnapshot;

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

    pub fn init(allocator: Allocator) Delta {
        return .{
            .accounts = std.AutoHashMap(ServiceId, ServiceAccount).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deepClone(self: *const Delta) !Delta {
        var clone = Delta.init(self.allocator);
        errdefer clone.deinit();

        // Iterate through all accounts in the source Delta
        var it = self.accounts.iterator();
        while (it.next()) |entry| {
            const account = entry.value_ptr;
            try clone.putAccount(entry.key_ptr.*, try account.deepClone(self.allocator));
        }

        return clone;
    }

    // TODO: change serviceindex to serviceid in types
    pub fn putAccount(self: *Delta, index: ServiceId, account: ServiceAccount) !void {
        if (self.accounts.contains(index)) return error.AccountAlreadyExists;
        try self.accounts.put(index, account);
    }

    pub fn getAccount(self: *const Delta, index: ServiceId) ?*ServiceAccount {
        return if (self.accounts.getPtr(index)) |account_ptr| account_ptr else null;
    }

    pub fn getOrCreateAccount(self: *Delta, index: ServiceId) !*ServiceAccount {
        if (self.getAccount(index)) |account| {
            return account;
        }
        var account = ServiceAccount.init(self.allocator);
        errdefer account.deinit();

        try self.putAccount(index, account);
        return self.getAccount(index).?;
    }

    pub fn updateBalance(self: *Delta, index: ServiceId, new_balance: Balance) !void {
        if (self.getAccount(index)) |account| {
            account.balance = new_balance;
        } else {
            return error.AccountNotFound;
        }
    }

    pub fn integratePreimage(self: *Delta, preimages: []const PreimageSubmission, t: Timeslot) !void {
        for (preimages) |item| {
            if (self.getAccount(item.index)) |account| {
                // Create structured preimage key using the service ID and hash
                const preimage_key = state_keys.constructServicePreimageKey(item.index, item.hash);
                try account.dupeAndAddPreimage(preimage_key, item.preimage);
                try account.registerPreimageAvailable(item.index, item.hash, @intCast(item.preimage.len), t);
            } else {
                return error.AccountNotFound;
            }
        }
    }

    pub fn deinit(self: *Delta) void {
        var it = self.accounts.valueIterator();
        while (it.next()) |account| {
            account.deinit();
        }
        self.accounts.deinit();
        self.* = undefined;
    }
};

// == Trace helpers

fn formatStateKey(key: types.StateKey) [19]u8 {
    var buf: [19]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}..{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        key[0],  key[1],  key[2],  key[3],
        key[27], key[28], key[29], key[30],
    }) catch unreachable;
    return buf;
}

const FormattedValue = struct {
    data: []const u8,
    truncated: bool,

    pub fn format(
        self: FormattedValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Write the hex data
        try writer.print("{s}", .{std.fmt.fmtSliceHexLower(self.data)});

        // If truncated, add indicator
        if (self.truncated) {
            try writer.writeAll("... (truncated)");
        }
    }
};

fn formatValue(value: []const u8) FormattedValue {
    const max_bytes = 512;
    if (value.len <= max_bytes) {
        return FormattedValue{
            .data = value,
            .truncated = false,
        };
    } else {
        return FormattedValue{
            .data = value[0..max_bytes],
            .truncated = true,
        };
    }
}
