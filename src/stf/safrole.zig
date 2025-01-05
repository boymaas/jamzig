const std = @import("std");

const types = @import("../types.zig");
const safrole = @import("../safrole.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const tracing = @import("../tracing.zig");
const trace = tracing.scoped(.stf);

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    extrinsic_tickets: types.TicketsExtrinsic,
) !safrole.Result {
    const span = trace.span(.transition_safrole);
    defer span.deinit();

    return try safrole.transition(
        params,
        stx,
        extrinsic_tickets,
    );
}
