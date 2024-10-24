const std = @import("std");
const math = std.math;
const mem = std.mem;

const Allocator = std.mem.Allocator;

// These constants are related to economic parameters
// Refer to Section 4.6 "Economics" for details on `BI`, `BL`, `BS`.
pub const B_S: Balance = 100;
pub const B_I: Balance = 10;
pub const B_L: Balance = 1;

pub const Transfer = struct {
    from: ServiceIndex,
    to: ServiceIndex,
    amount: Balance,
};

pub const Hash = [32]u8;
pub const ServiceIndex = u32;
pub const Balance = u64;
pub const GasLimit = u64;
pub const Timeslot = u32;

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
};

pub const PreimageLookupKey = struct {
    hash: Hash,
    length: u32,
};

pub const PreimageSubmission = struct {
    index: ServiceIndex,
    hash: Hash,
    preimage: []const u8,
};

pub const AccountUpdate = struct {
    index: ServiceIndex,
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

    pub fn deinit(self: *ServiceAccount) void {
        self.storage.deinit();

        var it = self.preimages.valueIterator();
        while (it.next()) |value| {
            self.preimages.allocator.free(value.*);
        }
        self.preimages.deinit();

        self.preimage_lookups.deinit();
    }

    // Functionality to read and write storage, reflecting access patterns in Section 4.9.2 on Service State.
    pub fn readStorage(self: *ServiceAccount, key: Hash) ?[]const u8 {
        return self.storage.get(key);
    }

    pub fn writeStorage(self: *ServiceAccount, key: Hash, value: []const u8) !void {
        const new_value = try self.storage.allocator.dupe(u8, value);
        try self.storage.put(key, new_value);
    }

    // Functions to add and manage preimages correspond to the discussion in Section 4.9.2 and Appendix D.
    pub fn addPreimage(self: *ServiceAccount, hash: Hash, preimage: []const u8) !void {
        const new_preimage = try self.preimages.allocator.dupe(u8, preimage);
        try self.preimages.put(hash, new_preimage);
    }

    pub fn getPreimage(self: *ServiceAccount, hash: Hash) ?[]const u8 {
        return self.preimages.get(hash);
    }

    pub fn integratePreimageLookup(self: *ServiceAccount, hash: Hash, length: u32, timeslot: Timeslot) !void {
        const key = PreimageLookupKey{ .hash = hash, .length = length };
        const lookup = self.preimage_lookups.get(key) orelse PreimageLookup{
            .status = .{ timeslot, null, null },
        };

        try self.preimage_lookups.put(key, lookup);
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
        const a_i: u32 = 2 * self.preimage_lookups.count() + self.storage.count();
        // a_l
        var plkeys = self.preimage_lookups.keyIterator();
        var a_l: u64 = 0;
        while (plkeys.next()) |key| {
            a_l += 81 + key.length;
        }

        var svals = self.storage.valueIterator();
        while (svals.next()) |value| {
            a_l += 32 + @as(u64, @intCast(value.len));
        }

        // a_t
        const a_t: Balance = B_S + B_I * a_i + B_L * a_l;

        return .{ .a_i = a_i, .a_l = a_l, .a_t = a_t };
    }
};

// `Delta` is the overarching structure that manages the state of the protocol
// and its various service accounts. As defined in GP0.4.1p@Ch9

pub const Delta = struct {
    accounts: std.AutoHashMap(ServiceIndex, ServiceAccount),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Delta {
        return .{
            .accounts = std.AutoHashMap(ServiceIndex, ServiceAccount).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("accounts");
        try jw.beginObject();

        var it = self.accounts.iterator();
        while (it.next()) |entry| {
            const index = entry.key_ptr.*;
            const account = entry.value_ptr.*;
            const account_index = try std.fmt.allocPrint(self.allocator, "{d}", .{index});
            defer self.allocator.free(account_index);
            try jw.objectField(account_index);
            // try jw.beginObjectFieldRaw();
            // try jw.write(index);
            // jw.endObjectFieldRaw();

            try jw.beginObject();

            try jw.objectField("balance");
            try jw.write(account.balance);

            try jw.objectField("min_gas_accumulate");
            try jw.write(account.min_gas_accumulate);

            try jw.objectField("min_gas_on_transfer");
            try jw.write(account.min_gas_on_transfer);

            try jw.objectField("code_hash");
            try jw.write(std.fmt.fmtSliceHexLower(&account.code_hash));

            try jw.objectField("storage");
            try jw.beginObject();
            var storage_it = account.storage.iterator();
            while (storage_it.next()) |storage_entry| {
                const key = std.fmt.fmtSliceHexLower(storage_entry.key_ptr).data;
                const value = std.fmt.fmtSliceHexLower(storage_entry.value_ptr.*);
                try jw.objectField(key);
                try jw.write(value);
            }
            try jw.endObject();

            try jw.objectField("preimage_lookups");
            try jw.beginObject();
            var lookup_it = account.preimage_lookups.iterator();
            while (lookup_it.next()) |lookup_entry| {
                const key = lookup_entry.key_ptr.*;
                const value = lookup_entry.value_ptr.*;
                const lookup_key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ std.fmt.fmtSliceHexLower(&key.hash), key.length });
                defer self.allocator.free(lookup_key);
                try jw.objectField(lookup_key);
                const value_str = try std.fmt.allocPrint(self.allocator, "{d},{d},{d}", .{ value.status[0] orelse 0, value.status[1] orelse 0, value.status[2] orelse 0 });
                defer self.allocator.free(value_str);
                try jw.write(value_str);
            }
            try jw.endObject();

            try jw.endObject();
        }

        try jw.endObject();
        try jw.endObject();
    }

    pub fn deinit(self: *Delta) void {
        var it = self.accounts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.accounts.deinit();
    }

    pub fn createAccount(self: *Delta, index: ServiceIndex) !void {
        if (self.accounts.contains(index)) return error.AccountAlreadyExists;
        const account = ServiceAccount.init(self.allocator);
        try self.accounts.put(index, account);
    }

    pub fn getAccount(self: *Delta, index: ServiceIndex) ?*ServiceAccount {
        return if (self.accounts.getPtr(index)) |account_ptr| account_ptr else null;
    }

    pub fn updateBalance(self: *Delta, index: ServiceIndex, new_balance: Balance) !void {
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

    pub fn postAccumulation(self: *Delta, updates: []const AccountUpdate) !void {
        for (updates) |update| {
            if (self.getAccount(update.index)) |account| {
                account.balance = update.new_balance;
                account.setMinGasAccumulate(update.new_gas_limit);
            } else {
                return error.AccountNotFound;
            }
        }
    }
    pub fn finalStateAfterTransfers(self: *Delta, transfers: []const Transfer) !void {
        for (transfers) |transfer| {
            const from_account = self.getAccount(transfer.from) orelse return error.AccountNotFound;
            const to_account = self.getAccount(transfer.to) orelse return error.AccountNotFound;

            if (from_account.balance < transfer.amount) return error.InsufficientBalance;

            from_account.balance -= transfer.amount;
            to_account.balance += transfer.amount;
        }
    }
};

// Tests validate the behavior of these structures as described in Section 4.2 and 4.9.
const testing = std.testing;

test "Delta initialization, account creation, and retrieval" {
    const allocator = testing.allocator;
    var delta = Delta.init(allocator);
    defer delta.deinit();

    const index: ServiceIndex = 1;
    try delta.createAccount(index);

    const account = delta.getAccount(index);
    try testing.expect(account != null);
    try testing.expect(account.?.balance == 0);

    try testing.expectError(error.AccountAlreadyExists, delta.createAccount(index));
}

test "Delta balance update" {
    const allocator = testing.allocator;
    var delta = Delta.init(allocator);
    defer delta.deinit();

    const index: ServiceIndex = 1;
    try delta.createAccount(index);

    const new_balance: Balance = 1000;
    try delta.updateBalance(index, new_balance);

    const account = delta.getAccount(index);
    try testing.expect(account != null);
    try testing.expect(account.?.balance == new_balance);

    const non_existent_index: ServiceIndex = 2;
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
