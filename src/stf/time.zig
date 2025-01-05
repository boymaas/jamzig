const std = @import("std");

const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const trace = @import("../tracing.zig").scoped(.stf);

pub const Error = error{
    bad_slot,
};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    header_slot: types.TimeSlot,
) !void {
    const span = trace.span(.transition_time);
    defer span.deinit();
    span.debug("Starting time transition", .{});

    const current_tau = try stx.ensure(.tau);
    if (header_slot <= current_tau.*) {
        span.err("Invalid slot: new slot {d} <= current tau {d}", .{ header_slot, current_tau });
        return error.BadSlot;
    }

    const tau_prime = try stx.ensure(.tau_prime);
    tau_prime.* = header_slot;
}
