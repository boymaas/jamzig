const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const accumulate = @import("../accumulate.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

/// Updates last_accumulation_slot for all services that were accumulated or received transfers
/// According to graypaper §12.24 equation 279
fn updateLastAccumulationSlot(
    comptime params: Params,
    stx: *StateTransition(params),
    result: *const accumulate.ProcessAccumulationResult,
) !void {
    const delta_prime = try stx.ensure(.delta_prime);

    // Update for accumulated services
    var iter = result.accumulation_stats.iterator();
    while (iter.next()) |entry| {
        if (delta_prime.getAccount(entry.key_ptr.*)) |account| {
            // Only update if the service was not created in this same slot
            // A service created in the current slot hasn't accumulated yet
            if (account.creation_slot != stx.time.current_slot) {
                account.last_accumulation_slot = stx.time.current_slot;
            }
        }
    }

    // Update for services that received transfers
    var transfer_iter = result.transfer_stats.iterator();
    while (transfer_iter.next()) |entry| {
        if (delta_prime.getAccount(entry.key_ptr.*)) |account| {
            // Only update if the service was not created in this same slot
            // A service created in the current slot that receives a transfer should update
            // But based on graypaper, newly created services shouldn't be in transfer_stats
            if (account.creation_slot != stx.time.current_slot) {
                account.last_accumulation_slot = stx.time.current_slot;
            }
        }
    }
}

pub const AccumulateResult = accumulate.ProcessAccumulationResult;

pub fn transition(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    reports: []types.WorkReport,
) !AccumulateResult {
    const span = trace.span(.accumulate);
    defer span.deinit();

    // Process the newly available reports
    const result = try accumulate.processAccumulationReports(
        IOExecutor,
        io_executor,
        params,
        allocator,
        stx,
        reports,
    );

    // Update last_accumulation_slot for all affected services
    try updateLastAccumulationSlot(params, stx, &result);

    return result;
}
