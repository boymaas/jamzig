const std = @import("std");
const math = std.math;
const mem = std.mem;

const types = @import("types.zig");

const Allocator = std.mem.Allocator;

// These constants are related to economic parameters
// Refer to Section 4.6 "Economics" for details on `BI`, `BL`, `BS`.
pub const B_S: Balance = 100;
pub const B_I: Balance = 10;
pub const B_L: Balance = 1;

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
    a_l: u64,
    a_t: Balance,
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
};

pub const PreimageLookupKey = struct {
    hash: Hash,
    length: u32,
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
    // Storage data on-chain
    storage: std.AutoHashMap(Hash, []u8),

    // Preimages for in-core access. This enables the Refine logic of the
    // service to use the data. The service manages this through its 'p'
    // (preimages) and 'l' (preimage_lookups) components.

    // Preimage data, once supplied, may not be removed freely; instead it goes
    // through a process of being marked as unavailable, and only after a period of
    // time may it be removed from state
    preimages: std.AutoHashMap(Hash, []u8),
    preimage_lookups: std.AutoHashMap(PreimageLookupKey, PreimageLookup),

    // Must be present in pre-image lookup, this in self.preimages
    code_hash: Hash,

    // The balance of the account, which is the amount of the native token held
    // by the account.
    balance: Balance,

    // The minumum gas limit before the accumulate and on transfer may be
    // executed
    min_gas_accumulate: GasLimit,
    min_gas_on_transfer: GasLimit,

    pub fn init(allocator: Allocator) ServiceAccount {
        return .{
            .storage = std.AutoHashMap(Hash, []u8).init(allocator),
            .preimages = std.AutoHashMap(Hash, []u8).init(allocator),
            .preimage_lookups = std.AutoHashMap(PreimageLookupKey, PreimageLookup).init(allocator),
            .code_hash = undefined,
            .balance = 0,
            .min_gas_accumulate = 0,
            .min_gas_on_transfer = 0,
        };
    }

    pub fn deepClone(self: *const ServiceAccount, allocator: Allocator) !ServiceAccount {
        var clone = ServiceAccount.init(allocator);
        errdefer clone.deinit();

        // Clone storage map
        var storage_it = self.storage.iterator();
        while (storage_it.next()) |entry| {
            const cloned_value = try allocator.dupe(u8, entry.value_ptr.*);
            try clone.storage.put(entry.key_ptr.*, cloned_value);
        }

        // Clone preimages map
        var preimage_it = self.preimages.iterator();
        while (preimage_it.next()) |entry| {
            const cloned_value = try allocator.dupe(u8, entry.value_ptr.*);
            try clone.preimages.put(entry.key_ptr.*, cloned_value);
        }

        // Clone preimage lookups
        var lookup_it = self.preimage_lookups.iterator();
        while (lookup_it.next()) |entry| {
            try clone.preimage_lookups.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Copy simple fields
        clone.code_hash = self.code_hash;
        clone.balance = self.balance;
        clone.min_gas_accumulate = self.min_gas_accumulate;
        clone.min_gas_on_transfer = self.min_gas_on_transfer;

        return clone;
    }

    pub fn deinit(self: *ServiceAccount) void {
        var storage_it = self.storage.valueIterator();
        while (storage_it.next()) |value| {
            self.storage.allocator.free(value.*);
        }
        self.storage.deinit();

        var it = self.preimages.valueIterator();
        while (it.next()) |value| {
            self.preimages.allocator.free(value.*);
        }
        self.preimages.deinit();

        self.preimage_lookups.deinit();
        self.* = undefined;
    }

    // Functionality to read and write storage, reflecting access patterns in Section 4.9.2 on Service State.
    pub fn readStorage(self: *ServiceAccount, key: Hash) ?[]const u8 {
        return self.storage.get(key);
    }

    pub fn resetStorage(self: *ServiceAccount, key: Hash) void {
        if (self.storage.getPtr(key)) |old_value_ptr| {
            self.storage.allocator.free(old_value_ptr.*);
            self.storage.put(key, &[_]u8{});
        }
    }

    pub fn removeStorage(self: *ServiceAccount, key: Hash) void {
        if (self.storage.getPtr(key)) |old_value_ptr| {
            self.storage.allocator.free(old_value_ptr.*);
            _ = self.storage.remove(key);
        }
    }

    pub fn writeStorage(self: *ServiceAccount, key: Hash, value: []const u8) !void {
        // Clear the old, otherwise we are leaking
        if (self.storage.getPtr(key)) |old_value_ptr| {
            self.storage.allocator.free(old_value_ptr.*);
        }

        const new_value = try self.storage.allocator.dupe(u8, value);
        try self.storage.put(key, new_value);
    }

    // Functions to add and manage preimages correspond to the discussion in Section 4.9.2 and Appendix D.
    pub fn addPreimage(self: *ServiceAccount, hash: Hash, preimage: []const u8) !void {
        const new_preimage = try self.preimages.allocator.dupe(u8, preimage);
        try self.preimages.put(hash, new_preimage);
    }

    pub fn getPreimage(self: *const ServiceAccount, hash: Hash) ?[]const u8 {
        return self.preimages.get(hash);
    }

    pub fn hasPreimage(self: *const ServiceAccount, hash: Hash) bool {
        return self.preimages.contains(hash);
    }

    //  PreImageLookups assume correct state, that is when you sollicit a
    //  preimage. It should not be available already.

    /// Created an entry in preimages_lookups indicating we need a preimage
    pub fn solicitPreimage(self: *ServiceAccount, hash: Hash, length: u32) !void {
        const key = PreimageLookupKey{ .hash = hash, .length = length };

        // Check if we already have an entry for this hash/length
        if (self.preimage_lookups.get(key)) |_| {
            return error.AlreadySolicited;
        } else {
            // If no lookup exists yet, create a new one with an empty status
            const new_lookup = PreimageLookup{
                .status = .{ null, null, null },
            };
            try self.preimage_lookups.put(key, new_lookup);
        }
    }

    // method to determine if this service needs a preimage
    pub fn needsPreImage(self: *const ServiceAccount, hash: Hash, length: u32, current_timeslot: Timeslot) bool {
        // Check if we have an entry in preimage_lookups
        const key = PreimageLookupKey{ .hash = hash, .length = length };

        if (self.preimage_lookups.get(key)) |*lookup| {
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
    pub fn registerPreImageAvailable(
        self: *ServiceAccount,
        hash: Hash,
        length: u32,
        timeslot: ?Timeslot,
    ) !void {
        const key = PreimageLookupKey{ .hash = hash, .length = length };

        // If we do not have one, easy just set first on and ready
        const existing_lookup = self.preimage_lookups.get(key) orelse {
            // If no lookup exists yet, create a new one with timeslot as the first entry
            const new_lookup = PreimageLookup{
                .status = .{ timeslot, null, null },
            };
            try self.preimage_lookups.put(key, new_lookup);
            return;
        };

        const status = existing_lookup.asSlice();

        // Create a modified lookup based on the existing one
        var updated_lookup = existing_lookup;

        // Update the status based on the current state:
        // - If all slots are null, set the first slot
        // - If first slot is set but second is and third null, set update te first slot
        // - If first and second slots are set, set the third slot (marking available again)
        if (status.len <= 1) {
            updated_lookup.status[0] = timeslot;
        } else if (status.len >= 2) {
            updated_lookup.status[2] = timeslot;
        }

        try self.preimage_lookups.put(key, updated_lookup);
    }

    // 9.2.2 Implement the historical lookup function
    pub fn historicalLookup(self: *ServiceAccount, time: Timeslot, hash: Hash) ?[]const u8 {
        // first get the preimage, if not return null
        if (self.getPreimage(hash)) |preimage| {
            // see if we have it in the lookup table
            if (self.preimage_lookups.get(PreimageLookupKey{ .hash = hash, .length = @intCast(preimage.len) })) |lookup| {
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

    pub fn storageFootprint(self: *const ServiceAccount) StorageFootprint {
        // a_i
        const a_i: u32 = (2 * self.preimage_lookups.count()) + self.storage.count();
        // a_l
        var plkeys = self.preimage_lookups.keyIterator();
        var a_l: u64 = 0;
        while (plkeys.next()) |plkey| {
            a_l += 81 + plkey.length;
        }

        var svals = self.storage.valueIterator();
        while (svals.next()) |value| {
            a_l += 32 + @as(u64, @intCast(value.len));
        }

        // FIXME: this comes for JamParams
        // a_t
        const a_t: Balance = B_S + B_I * a_i + B_L * a_l;

        return .{ .a_i = a_i, .a_l = a_l, .a_t = a_t };
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
        try @import("state_format/delta.zig").format(self, fmt, options, writer);
    }

    pub fn init(allocator: Allocator) Delta {
        return .{
            .accounts = std.AutoHashMap(ServiceId, ServiceAccount).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try @import("state_json/services.zig").jsonStringify(self, jw);
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
                try account.addPreimage(item.hash, item.preimage);
                try account.integratePreimageLookup(item.hash, @intCast(item.preimage.len), t);
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

// Tests validate the behavior of these structures as described in Section 4.2 and 4.9.
const testing = std.testing;

test "Delta initialization, account creation, and retrieval" {
    const allocator = testing.allocator;
    var delta = Delta.init(allocator);
    defer delta.deinit();

    const index: ServiceId = 1;
    _ = try delta.getOrCreateAccount(index);
}

test "Delta balance update" {
    const allocator = testing.allocator;
    var delta = Delta.init(allocator);
    defer delta.deinit();

    const index: ServiceId = 1;
    _ = try delta.getOrCreateAccount(index);

    const new_balance: Balance = 1000;
    try delta.updateBalance(index, new_balance);

    const account = delta.getAccount(index);
    try testing.expect(account != null);
    try testing.expect(account.?.balance == new_balance);

    const non_existent_index: ServiceId = 2;
    try testing.expectError(error.AccountNotFound, delta.updateBalance(non_existent_index, new_balance));
}

test "ServiceAccount initialization and deinitialization" {
    const allocator = testing.allocator;
    var account = ServiceAccount.init(allocator);
    defer account.deinit();

    try testing.expect(account.storage.count() == 0);
    try testing.expect(account.preimages.count() == 0);
    try testing.expect(account.preimage_lookups.count() == 0);
    try testing.expect(account.balance == 0);
    try testing.expect(account.min_gas_accumulate == 0);
    try testing.expect(account.min_gas_on_transfer == 0);
}

test "ServiceAccount historicalLookup" {
    const allocator = testing.allocator;
    var account = ServiceAccount.init(allocator);
    defer account.deinit();

    const hash = [_]u8{1} ** 32;
    const preimage = "test preimage";

    try account.addPreimage(hash, preimage);

    const key = PreimageLookupKey{ .hash = hash, .length = @intCast(preimage.len) };

    // Test case 1: Empty status
    try account.preimage_lookups.put(key, PreimageLookup{ .status = .{ null, null, null } });
    try testing.expectEqual(null, account.historicalLookup(5, hash));

    // Test case 2: Status with 1 entry
    try account.preimage_lookups.put(key, PreimageLookup{ .status = .{ 10, null, null } });
    try testing.expectEqual(null, account.historicalLookup(5, hash));
    try testing.expectEqualStrings(preimage, account.historicalLookup(15, hash).?);

    // Test case 3: Status with 2 entries
    try account.preimage_lookups.put(key, PreimageLookup{ .status = .{ 10, 20, null } });
    try testing.expectEqualStrings(preimage, account.historicalLookup(15, hash).?);
    try testing.expectEqual(null, account.historicalLookup(25, hash));

    // Test case 4: Status with 3 entries
    try account.preimage_lookups.put(key, PreimageLookup{ .status = .{ 10, 20, 30 } });
    try testing.expectEqual(null, account.historicalLookup(5, hash));
    try testing.expectEqualStrings(preimage, account.historicalLookup(15, hash).?);
    try testing.expectEqual(null, account.historicalLookup(25, hash));
    try testing.expectEqualStrings(preimage, account.historicalLookup(35, hash).?);

    // Test case 5: Non-existent hash
    const non_existent_hash = [_]u8{2} ** 32;
    try testing.expectEqual(null, account.historicalLookup(15, non_existent_hash));

    // Test case 6: Preimage doesn't exist in preimages
    const hash_without_preimage = [_]u8{3} ** 32;
    try account.preimage_lookups.put(
        PreimageLookupKey{ .hash = hash_without_preimage, .length = 10 },
        PreimageLookup{ .status = .{ 10, 0, 0 } },
    );
    try testing.expect(account.historicalLookup(15, hash_without_preimage) == null);
}
