
const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_delta = @import("../state_delta.zig");
const accumulate = @import("../accumulate.zig");

const services = @import("../services.zig");
const state_theta = @import("../reports_ready.zig");
const state_keys = @import("../state_keys.zig");
const validator_stats = @import("../validator_stats.zig");
const accumulation_outputs = @import("../accumulation_outputs.zig");

const tv_types = @import("../jamtestvectors/accumulate.zig");
const jam_types = @import("../jamtestvectors/jam_types.zig");
const Params = @import("../jam_params.zig").Params;

pub fn convertTestStateIntoJamState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    test_state: tv_types.State,
) !state.JamState(params) {
    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    jam_state.tau = test_state.slot;
    jam_state.eta = [_][32]u8{test_state.entropy} ++ [_][32]u8{[_]u8{0} ** 32} ** 3;

    jam_state.iota = try types.ValidatorSet.init(allocator, 0);
    jam_state.phi = try state.Phi(
        params.core_count,
        params.max_authorizations_queue_items,
    ).init(allocator);

    jam_state.delta = try convertServiceAccounts(
        allocator,
        test_state.accounts,
    );

    jam_state.chi = try convertPrivileges(
        params.core_count,
        allocator,
        test_state.privileges,
    );

    jam_state.vartheta = try convertReadyQueue(
        params.epoch_length,
        allocator,
        test_state.ready_queue,
    );

    jam_state.xi = try convertAccumulatedQueue(
        params.epoch_length,
        allocator,
        test_state.accumulated,
    );

    jam_state.pi = try convertServiceStatistics(
        allocator,
        test_state.statistics,
        params.validators_count,
        params.core_count,
    );

    jam_state.theta = accumulation_outputs.Theta.init(allocator);

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

    const core_service_info = account.data.service.toCore();

    service_account.code_hash = core_service_info.code_hash;
    service_account.balance = core_service_info.balance;
    service_account.min_gas_accumulate = core_service_info.min_item_gas;
    service_account.min_gas_on_transfer = core_service_info.min_memo_gas;
    service_account.footprint_bytes = core_service_info.bytes;
    service_account.footprint_items = core_service_info.items;
    
    service_account.last_accumulation_slot = account.data.service.last_accumulation_slot;
    service_account.creation_slot = account.data.service.creation_slot;
    service_account.parent_service = account.data.service.parent_service;
    service_account.storage_offset = account.data.service.deposit_offset;

    for (account.data.preimage_blobs) |preimage| {
        const preimage_key = state_keys.constructServicePreimageKey(account.id, preimage.hash);
        try service_account.dupeAndAddPreimage(preimage_key, preimage.blob);
    }

    for (account.data.preimage_requests) |request| {
        const timeslot: types.TimeSlot = if (request.value.len > 0) request.value[0] else 0;
        try service_account.registerPreimageAvailableNoFootprint(
            account.id,
            request.key.hash,
            request.key.length,  // v0.7.2: length is now part of the key
            timeslot
        );
    }

    for (account.data.storage) |storage_entry| {
        try service_account.writeStorageNoFootprint(account.id, storage_entry.key, try allocator.dupe(u8, storage_entry.value));
    }

    return service_account;
}

pub fn convertPrivileges(comptime core_count: u16, allocator: std.mem.Allocator, privileges: tv_types.Privileges) !state.Chi(core_count) {
    std.debug.assert(privileges.assign.len == core_count);
    
    var chi = try state.Chi(core_count).init(allocator);
    errdefer chi.deinit();

    chi.manager = privileges.bless;
    @memcpy(&chi.assign, privileges.assign);
    chi.designate = privileges.designate;

    for (privileges.always_acc) |item| {
        try chi.always_accumulate.put(item.id, item.gas);
    }

    return chi;
}

pub fn convertReadyQueue(
    comptime epoch_size: usize,
    allocator: std.mem.Allocator,
    ready_queue: tv_types.ReadyQueue,
) !state.VarTheta(epoch_size) {
    var theta = state.VarTheta(epoch_size).init(allocator);
    errdefer theta.deinit();

    for (ready_queue.items, 0..) |slot_records, slot_index| {
        if (slot_records.len == 0) continue;

        var slot_entries = &theta.entries[slot_index];

        for (slot_records) |slot_record| {
            var cloned_slot_report = try slot_record.report.deepClone(allocator);
            errdefer cloned_slot_report.deinit(allocator);

            var entry = try state_theta.WorkReportAndDeps.initWithDependencies(
                allocator,
                cloned_slot_report,
                slot_record.dependencies,
            );
            errdefer entry.deinit(allocator);

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
        try xi.shiftDown();
        for (queue_items) |queue_item| {
            try xi.addWorkPackage(queue_item);
        }
    }

    return xi;
}

pub fn convertServiceStatistics(
    allocator: std.mem.Allocator,
    statistics: jam_types.ServiceStatistics,
    validator_count: usize,
    core_count: usize,
) !validator_stats.Pi {
    var pi = try validator_stats.Pi.init(allocator, validator_count, core_count);
    errdefer pi.deinit();

    for (statistics.stats) |stat_entry| {
        const service_id = stat_entry.id;
        const record = stat_entry.record;

        const service_stats = try pi.getOrCreateServiceStats(service_id);

        service_stats.accumulate_count = record.accumulate_count;
        service_stats.accumulate_gas_used = record.accumulate_gas_used;

        service_stats.provided_count = record.provided_count;
        service_stats.provided_size = record.provided_size;
        service_stats.refinement_count = record.refinement_count;
        service_stats.refinement_gas_used = record.refinement_gas_used;
        service_stats.imports = record.imports;
        service_stats.exports = record.exports;
        service_stats.extrinsic_size = record.extrinsic_size;
        service_stats.extrinsic_count = record.extrinsic_count;
    }

    return pi;
}
