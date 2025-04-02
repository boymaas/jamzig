const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const tvector = @import("../jamtestvectors/reports.zig");

pub fn convertAvailabilityAssignments(
    comptime core_count: u16,
    allocator: std.mem.Allocator,
    assignments: types.AvailabilityAssignments,
) !state.Rho(core_count) {
    var rho = state.Rho(core_count).init(allocator);
    errdefer rho.deinit();

    for (assignments.items, 0..) |assignment, core| {
        if (assignment) |a| {
            rho.setReport(core, try a.deepClone(allocator));
        }
    }
    return rho;
}

pub fn convertValidatorSet(
    allocator: std.mem.Allocator,
    validator_set: types.ValidatorSet,
) !types.ValidatorSet {
    return try validator_set.deepClone(allocator);
}

pub fn convertBeta(
    allocator: std.mem.Allocator,
    blocks: []types.BlockInfo,
    max_blocks: usize,
) !state.Beta {
    var beta = try state.Beta.init(allocator, max_blocks);
    errdefer beta.deinit();

    for (blocks) |block| {
        try beta.addBlockInfo(try block.deepClone(allocator));
    }

    return beta;
}

pub fn convertAuthPools(
    auth_pools: tvector.AuthPools,
    comptime core_count: u16,
    comptime max_pool_items: u8,
) state.Alpha(core_count, max_pool_items) {
    var alpha = state.Alpha(core_count, max_pool_items).init();

    for (auth_pools.pools, 0..) |pool, core| {
        for (pool) |hash| {
            alpha.addAuthorizer(core, hash) catch unreachable;
        }
    }

    return alpha;
}

pub fn convertAccounts(
    allocator: std.mem.Allocator,
    accounts: []tvector.AccountsMapEntry,
) !state.Delta {
    var delta = state.Delta.init(allocator);
    errdefer delta.deinit();

    for (accounts) |account_entry| {
        var service_account = @import("../services.zig").ServiceAccount.init(allocator);
        service_account.code_hash = account_entry.data.service.code_hash;
        service_account.balance = account_entry.data.service.balance;
        service_account.min_gas_accumulate = account_entry.data.service.min_item_gas;
        service_account.min_gas_on_transfer = account_entry.data.service.min_memo_gas;
        try delta.putAccount(account_entry.id, service_account);
    }

    return delta;
}

pub fn convertCoreStatistics(
    allocator: std.mem.Allocator,
    cores_statistics: tvector.CoresStatistics,
    validators_count: u32,
    core_count: u16,
) !state.Pi {
    var pi = try state.Pi.init(allocator, validators_count, core_count);
    errdefer pi.deinit();

    // Copy core statistics
    for (cores_statistics.stats, 0..) |core_stat, i| {
        if (i < pi.core_stats.items.len) {
            pi.core_stats.items[i] = core_stat;
        }
    }

    return pi;
}

pub fn convertServiceStatistics(
    pi: *state.Pi,
    services_statistics: []state.validator_stats.ServiceActivityRecord,
    services_map: []tvector.AccountsMapEntry,
) !void {
    // Copy service statistics
    for (services_map, 0..) |service_entry, i| {
        if (i < services_statistics.len) {
            try pi.service_stats.put(service_entry.id, services_statistics[i]);
        }
    }
}

const StateInitError = error{
    InvalidAuthPoolsCount,
    InvalidAccountsCount,
    InvalidValidatorCount,
    InvalidOffenderCount,
};

pub fn convertOffenders(
    allocator: std.mem.Allocator,
    offenders: []types.Ed25519Public,
    validators_count: u32,
) ![]types.Ed25519Public {
    if (offenders.len > validators_count) {
        return StateInitError.InvalidOffenderCount;
    }
    return try allocator.dupe(types.Ed25519Public, offenders);
}

pub fn convertState(
    comptime params: @import("../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    test_state: tvector.State,
) !state.JamState(params) {
    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // Validate and convert availability assignments
    jam_state.rho = try convertAvailabilityAssignments(
        params.core_count,
        allocator,
        test_state.avail_assignments,
    );

    // Validate and convert validator sets
    if (test_state.curr_validators.validators.len != params.validators_count) {
        return StateInitError.InvalidValidatorCount;
    }
    jam_state.kappa = try convertValidatorSet(allocator, test_state.curr_validators);

    if (test_state.prev_validators.validators.len != params.validators_count) {
        return StateInitError.InvalidValidatorCount;
    }
    jam_state.lambda = try convertValidatorSet(allocator, test_state.prev_validators);

    // Set entropy buffer
    jam_state.eta = test_state.entropy;

    // Convert recent blocks history
    jam_state.beta = try convertBeta(allocator, test_state.recent_blocks, params.recent_history_size);

    // Validate and convert auth pools
    if (test_state.auth_pools.pools.len != params.core_count) {
        return StateInitError.InvalidAuthPoolsCount;
    }
    jam_state.alpha = convertAuthPools(test_state.auth_pools, params.core_count, params.max_authorizations_pool_items);

    // Convert service accounts from the new accounts field
    jam_state.delta = try convertAccounts(allocator, test_state.accounts);

    // Convert core statistics and initialize Pi component
    jam_state.pi = try convertCoreStatistics(allocator, test_state.cores_statistics, params.validators_count, params.core_count);

    // Add service statistics to the Pi component
    try convertServiceStatistics(&jam_state.pi.?, test_state.services_statistics, test_state.accounts);

    // Convert offenders list
    // const converted_offenders = try convertOffenders(allocator, test_state.offenders, params.validators_count);
    // // TODO: do something with these offenders
    // defer allocator.free(converted_offenders);

    return jam_state;
}
