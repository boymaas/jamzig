const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const accumulate = @import("../accumulate.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("tracing");
const trace = tracing.scoped(.stf);

pub const Error = error{};

/// Updates last_accumulation_slot for services with non-empty work-digests (N(s) ≠ [])
/// Per graypaper v0.7.1 eq 12.26: only services in keys(accumulationstatistics) are updated
fn updateLastAccumulationSlot(
    comptime params: Params,
    stx: *StateTransition(params),
    result: *const accumulate.ProcessAccumulationResult,
) !void {
    const delta_prime = try stx.ensure(.delta_prime);

    // Update only services with work-digests (in accumulation_stats per eq 12.25)
    var iter = result.accumulation_stats.iterator();
    while (iter.next()) |entry| {
        if (delta_prime.getAccount(entry.key_ptr.*)) |account| {
            // Only update if the service was not created in this same slot
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
    const span = trace.span(@src(), .accumulate);
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
