const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const accumulate = @import("../accumulate.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    _: std.mem.Allocator,
    stx: *StateTransition(params),
    reports: []types.WorkReport,
) !accumulate.ProcessAccumulationResult {
    const span = trace.span(.accumulate);
    defer span.deinit();

    // Process the newly available reports
    const result = try accumulate.processAccumulateReports(
        params,
        stx,
        reports,
    );

    return result;
}
