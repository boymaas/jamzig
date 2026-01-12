const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const state_keys = @import("../state_keys.zig");

const tv_types = @import("../jamtestvectors/preimages.zig");
const Params = @import("../jam_params.zig").Params;

pub fn convertTestStateIntoJamState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_state: tv_types.State,
    tau: types.TimeSlot,
) !state.JamState(params) {
    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    jam_state.tau = tau;

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
        const service_account = try convertAccount(allocator, account_entry.id, account_entry.data);
        try delta.accounts.put(account_entry.id, service_account);
    }

    return delta;
}

pub fn convertAccount(allocator: std.mem.Allocator, service_id: u32, account: tv_types.Account) !state.services.ServiceAccount {
    var service_account = state.services.ServiceAccount.init(allocator);
    errdefer service_account.deinit();

    for (account.preimages) |preimage_entry| {
        const preimage_key = state_keys.constructServicePreimageKey(service_id, preimage_entry.hash);
        try service_account.dupeAndAddPreimage(preimage_key, preimage_entry.blob);
    }

    for (account.lookup_meta) |lookup_entry| {
        var pre_image_lookup = state.services.PreimageLookup{
            .status = .{ null, null, null },
        };

        for (lookup_entry.value, 0..) |slot, idx| {
            pre_image_lookup.status[idx] = slot;
        }

        const lookup_key = state_keys.constructServicePreimageLookupKey(
            service_id,
            lookup_entry.key.length,
            lookup_entry.key.hash,
        );

        const encoded = try state.services.ServiceAccount.encodePreimageLookup(allocator, pre_image_lookup);
        try service_account.data.put(lookup_key, encoded);
    }

    service_account.code_hash = [_]u8{0} ** 32;
    service_account.balance = 1000;
    service_account.min_gas_accumulate = 1000;
    service_account.min_gas_on_transfer = 1000;

    return service_account;
}
