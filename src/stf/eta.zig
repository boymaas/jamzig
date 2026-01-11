const std = @import("std");

const state_d = @import("../state_delta.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = state_d.StateTransition;

const trace = @import("tracing").scoped(.stf);

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    new_entropy: types.Entropy,
) !void {
    const span = trace.span(@src(), .transition_eta);
    defer span.deinit();

    var eta_current = try stx.ensure(.eta);
    var eta_prime = try stx.ensure(.eta_prime);
    if (stx.time.isNewEpoch()) {
        span.trace("Rotating entropy values: eta[2]={any}, eta[1]={any}, eta[0]={any}", .{
            std.fmt.fmtSliceHexLower(&eta_current[2]),
            std.fmt.fmtSliceHexLower(&eta_current[1]),
            std.fmt.fmtSliceHexLower(&eta_current[0]),
        });

        eta_prime[3] = eta_current[2];
        eta_prime[2] = eta_current[1];
        eta_prime[1] = eta_current[0];
    }

    const entropy = @import("../entropy.zig");
    eta_prime[0] = entropy.update(eta_current[0], new_entropy);

    span.trace("New eta[0] after entropy update: {any}", .{std.fmt.fmtSliceHexLower(&eta_prime[0])});
}
