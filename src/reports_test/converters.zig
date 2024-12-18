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
        try beta.addBlockInfo(block);
    }

    return beta;
}

pub fn convertAuthPools(
    allocator: std.mem.Allocator,
    auth_pools: tvector.AuthPools,
    comptime core_count: u16,
) !state.Phi(core_count) {
    var phi = try state.Phi(core_count).init(allocator);
    errdefer phi.deinit();

    for (auth_pools.pools, 0..) |pool, core| {
        for (pool) |hash| {
            try phi.addAuthorization(core, hash);
        }
    }

    return phi;
}

pub fn convertServices(
    allocator: std.mem.Allocator,
    services: []tvector.ServiceItem,
) !state.Delta {
    var delta = state.Delta.init(allocator);
    errdefer delta.deinit();

    for (services) |service| {
        var account = @import("../services.zig").ServiceAccount.init(allocator);
        account.code_hash = service.info.code_hash;
        account.balance = service.info.balance;
        account.min_gas_accumulate = service.info.min_item_gas;
        account.min_gas_on_transfer = service.info.min_memo_gas;
        try delta.putAccount(service.id, account);
    }

    return delta;
}

pub fn convertState(
    comptime params: @import("../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    test_state: tvector.State,
) !state.JamState(params) {
    var jam_state = try state.JamState(params).init(allocator);

    jam_state.rho = try convertAvailabilityAssignments(
        params.core_count,
        allocator,
        test_state.avail_assignments,
    );

    jam_state.kappa = try convertValidatorSet(allocator, test_state.curr_validators);
    jam_state.lambda = try convertValidatorSet(allocator, test_state.prev_validators);
    jam_state.eta = test_state.entropy;

    jam_state.beta = try convertBeta(allocator, test_state.recent_blocks, params.recent_history_size);

    // Convert directly into final state objects
    jam_state.phi = try convertAuthPools(allocator, test_state.auth_pools, params.core_count);
    jam_state.delta = try convertServices(allocator, test_state.services);

    return jam_state;
}
