const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");

const tv_types = @import("../jamtestvectors/preimages.zig");
const Params = @import("../jam_params.zig").Params;

pub fn convertTestStateIntoJamState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_state: tv_types.State,
    tau: types.TimeSlot,
) !state.JamState(params) {
    // Create a JamState to use as the base state
    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // Initial tau as a placeholder, will be updated from test vector
    jam_state.tau = tau;

    // Set up delta (service accounts)
    jam_state.delta = try convertAccountsEntries(
        allocator,
        test_state.accounts,
    );

    return jam_state;
}

pub fn convertAccountsEntries(
    allocator: std.mem.Allocator,
    accounts: []tv_types.AccountsMapEntry,
) !state.Delta {
    var delta = state.Delta.init(allocator);
    errdefer delta.deinit();

    for (accounts) |account_entry| {
        const service_account = try convertAccount(allocator, account_entry.data);
        try delta.accounts.put(account_entry.id, service_account);
    }

    return delta;
}

pub fn convertAccount(allocator: std.mem.Allocator, account: tv_types.Account) !state.services.ServiceAccount {
    var service_account = state.services.ServiceAccount.init(allocator);
    errdefer service_account.deinit();

    // Add preimages
    for (account.preimages) |preimage_entry| {
        try service_account.addPreimage(preimage_entry.hash, preimage_entry.blob);
    }

    // Add lookup metadata
    for (account.lookup_meta) |lookup_entry| {
        var pre_image_lookup = state.services.PreimageLookup{
            .status = .{ null, null, null },
        };

        for (lookup_entry.value, 0..) |slot, idx| {
            pre_image_lookup.status[idx] = slot;
        }

        try service_account.preimage_lookups.put(
            state.services.PreimageLookupKey{
                .hash = lookup_entry.key.hash,
                .length = lookup_entry.key.length,
            },
            pre_image_lookup,
        );
    }

    // Set up a basic service info with default values
    service_account.code_hash = [_]u8{0} ** 32;
    service_account.balance = 1000;
    service_account.min_gas_accumulate = 1000;
    service_account.min_gas_on_transfer = 1000;

    return service_account;
}
