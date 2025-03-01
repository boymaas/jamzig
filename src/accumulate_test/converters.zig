const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const accumulate = @import("../accumulate.zig");

const services = @import("../services.zig");
const state_theta = @import("../available_reports.zig");

const tv_types = @import("../jamtestvectors/accumulate.zig");
const Params = @import("../jam_params.zig").Params;

pub fn convertTestStateIntoJamState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_state: tv_types.State,
) !state.JamState(params) {
    // Create a JamState to use as the base state
    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    jam_state.tau = test_state.slot;
    jam_state.eta = [_][32]u8{test_state.entropy} ++ [_][32]u8{[_]u8{0} ** 32} ** 3;

    // Convert and set the individual components
    jam_state.delta = try convertServiceAccounts(
        allocator,
        test_state.accounts,
    );

    jam_state.chi = try convertPrivileges(
        allocator,
        test_state.privileges,
    );

    jam_state.theta = try convertReadyQueue(
        params.epoch_length,
        allocator,
        test_state.ready_queue,
    );

    jam_state.xi = try convertAccumulatedQueue(
        params.epoch_length,
        allocator,
        test_state.accumulated,
    );

    return jam_state;
}

pub fn convertServiceAccounts(
    allocator: std.mem.Allocator,
    accounts: []tv_types.ServiceAccount,
) !state.Delta {
    var delta = state.Delta.init(allocator);
    errdefer delta.deinit();

    for (accounts) |account| {
        try delta.accounts.put(account.id, try convertServiceAccount(allocator, account));
    }

    return delta;
}

pub fn convertServiceAccount(allocator: std.mem.Allocator, account: tv_types.ServiceAccount) !state.services.ServiceAccount {
    var service_account = state.services.ServiceAccount.init(allocator);
    errdefer service_account.deinit();

    // Set the code hash and basic account info
    service_account.code_hash = account.data.service.code_hash;
    service_account.balance = account.data.service.balance;
    service_account.min_gas_accumulate = account.data.service.min_item_gas;
    service_account.min_gas_on_transfer = account.data.service.min_memo_gas;

    // Add all preimages
    for (account.data.preimages) |preimage| {
        try service_account.addPreimage(preimage.hash, preimage.blob);
        try service_account.integratePreimageLookup(preimage.hash, @intCast(preimage.blob.len), null);
    }

    return service_account;
}

pub fn convertPrivileges(allocator: std.mem.Allocator, privileges: tv_types.Privileges) !state.Chi {
    var chi = state.Chi.init(allocator);
    errdefer chi.deinit();

    // Map the privileged service identities
    chi.manager = privileges.bless;
    chi.assign = privileges.assign;
    chi.designate = privileges.designate;

    // Add all always-accumulate mappings
    for (privileges.always_acc) |item| {
        try chi.always_accumulate.put(item.id, item.gas);
    }

    return chi;
}

pub fn convertReadyQueue(
    comptime epoch_size: usize,
    allocator: std.mem.Allocator,
    ready_queue: tv_types.ReadyQueue,
) !state.Theta(epoch_size) {
    var theta = state.Theta(epoch_size).init(allocator);
    errdefer theta.deinit();

    // Initialize the ready queue items for each epoch slot
    for (ready_queue.items, 0..) |slot_records, slot_index| {
        // Skip if no records for this slot
        if (slot_records.len == 0) continue;

        // Create a new ready queue entry for this slot
        var slot_entries = theta.entries[slot_index];

        // Convert each record in the slot
        for (slot_records) |slot_record| {
            const entry = try state_theta.WorkReportAndDeps.initWithDependencies(
                allocator,
                try slot_record.report.deepClone(allocator),
                slot_record.dependencies,
            );
            try slot_entries.append(allocator, entry);
        }
    }

    return theta;
}

pub fn convertAccumulatedQueue(
    comptime epoch_size: usize,
    allocator: std.mem.Allocator,
    accumulated: tv_types.AccumulatedQueue,
) !state.Xi(epoch_size) {
    var xi = state.Xi(epoch_size).init(allocator);
    errdefer xi.deinit();

    for (accumulated.items) |queue_items| {
        for (queue_items) |queue_item| {
            try xi.addWorkPackage(queue_item);
        }
        try xi.shiftDown();
    }

    return xi;
}
