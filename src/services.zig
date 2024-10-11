const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Hash = [32]u8;
pub const ServiceIndex = u32;
pub const Balance = u64;
pub const GasLimit = u64;
pub const Timeslot = u32;

pub const PreimageLookup = struct {
    status: [3]?Timeslot,
    length: u32,
};

pub const PreimageLookupKey = struct {
    hash: Hash,
    length: u32,
};

pub const ServiceAccount = struct {
    storage: std.AutoHashMap(Hash, []u8),
    preimages: std.AutoHashMap(Hash, []u8),
    preimage_lookups: std.AutoHashMap(PreimageLookupKey, PreimageLookup),
    code_hash: Hash,
    balance: Balance,
    gas_limit: GasLimit,
    min_gas_limit: GasLimit,

    pub fn init(allocator: Allocator) ServiceAccount {
        return .{
            .storage = std.AutoHashMap(Hash, []u8).init(allocator),
            .preimages = std.AutoHashMap(Hash, []u8).init(allocator),
            .preimage_lookups = std.AutoHashMap(PreimageLookupKey, PreimageLookup).init(allocator),
            .code_hash = undefined,
            .balance = 0,
            .gas_limit = 0,
            .min_gas_limit = 0,
        };
    }

    pub fn deinit(self: *ServiceAccount) void {
        self.storage.deinit();
        self.preimages.deinit();
        self.preimage_lookups.deinit();
    }

    // Add more methods here for operations on ServiceAccount
};

pub const Delta = struct {
    accounts: std.AutoHashMap(ServiceIndex, ServiceAccount),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Delta {
        return .{
            .accounts = std.AutoHashMap(ServiceIndex, ServiceAccount).init(allocator),
            .allocator = allocator,
        };
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
};

const testing = std.testing;

test "ServiceAccount initialization and deinitialization" {
    const allocator = testing.allocator;
    var account = ServiceAccount.init(allocator);
    defer account.deinit();

    try testing.expect(account.storage.count() == 0);
    try testing.expect(account.preimages.count() == 0);
    try testing.expect(account.preimage_lookups.count() == 0);
    try testing.expect(account.balance == 0);
    try testing.expect(account.gas_limit == 0);
    try testing.expect(account.min_gas_limit == 0);
}

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
