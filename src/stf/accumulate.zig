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
            account.last_accumulation_slot = stx.time.current_slot;
        }
    }
    
    // Update for services that received transfers
    var transfer_iter = result.transfer_stats.iterator();
    while (transfer_iter.next()) |entry| {
        if (delta_prime.getAccount(entry.key_ptr.*)) |account| {
            account.last_accumulation_slot = stx.time.current_slot;
        }
    }
}

pub fn transition(
    comptime params: Params,
    _: std.mem.Allocator,
    stx: *StateTransition(params),
    reports: []types.WorkReport,
) !accumulate.ProcessAccumulationResult {
    const span = trace.span(.accumulate);
    defer span.deinit();

    // Process the newly available reports
    const result = try accumulate.processAccumulationReports(
        params,
        stx,
        reports,
    );

    // Update last_accumulation_slot for all affected services
    try updateLastAccumulationSlot(params, stx, &result);

    return result;
}
