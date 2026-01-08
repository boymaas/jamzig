const std = @import("std");
const Allocator = std.mem.Allocator;

const state = @import("../state.zig");
const types = @import("../types.zig");
const tracing = @import("tracing");
const trace = tracing.scoped(.stf_authorization);

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;
const auth = @import("../authorizations.zig");

pub const Error = error{};

pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    xtguarantees: types.GuaranteesExtrinsic,
) !void {
    const span = trace.span(@src(), .authorization);
    defer span.deinit();

    span.debug("Processing authorizations from guarantees in STF for slot {d}", .{stx.time.current_slot});
    span.debug("Number of guarantees: {d}", .{xtguarantees.data.len});

    var authorizers = std.ArrayList(auth.CoreAuthorizer).init(stx.allocator);
    defer authorizers.deinit();

    for (xtguarantees.data) |guarantee| {
        try authorizers.append(auth.CoreAuthorizer{
            .core = guarantee.report.core_index.value,
            .auth_hash = guarantee.report.authorizer_hash,
        });
    }

    try auth.processAuthorizations(
        params,
        stx,
        authorizers.items,
    );

    span.debug("Authorization processing completed successfully", .{});
}
