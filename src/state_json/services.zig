const std = @import("std");

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
