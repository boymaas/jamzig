/// Adapts the TestVector format to our transition function
const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");
const safrole_test_vector = @import("../jamtestvectors/safrole.zig");
const stf = @import("../stf.zig");
const safrole = @import("../safrole.zig");
const dstate = @import("../state_delta.zig");

const Allocator = std.mem.Allocator;
const Params = @import("../jam_params.zig").Params;

// Constant
pub const TransitionResult = struct {
    output: safrole_test_vector.Output,
    state: ?safrole_test_vector.State,

    pub fn deinit(self: TransitionResult, allocator: std.mem.Allocator) void {
        if (self.state != null) {
            self.state.?.deinit(allocator);
        }
        self.output.deinit(allocator);
    }
};

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    pre_state: safrole_test_vector.State,
    input: safrole_test_vector.Input,
) !TransitionResult {
    var current_state = state.JamState(params){};
    defer current_state.deinit(allocator);

    current_state.psi = init_psi: {
        var current_psi = state.Psi.init(allocator);
        errdefer current_psi.deinit();
        try current_psi.registerOffenders(pre_state.post_offenders);
        break :init_psi current_psi;
    };
    current_state.tau = pre_state.gamma.tau;
    current_state.eta = pre_state.gamma.eta;
    current_state.lambda = try pre_state.gamma.lambda.deepClone(allocator);
    current_state.kappa = try pre_state.gamma.kappa.deepClone(allocator);
    current_state.gamma = try GammaFromTestVectorState(
        params.validators_count,
        params.epoch_length,
        allocator,
        pre_state,
    );
    current_state.iota = try pre_state.gamma.iota.deepClone(allocator);

    const transition_time = params.Time().init(current_state.tau.?, input.slot);
    var stx = try dstate.StateTransition(params).init(allocator, &current_state, transition_time);
    defer stx.deinit();

    var result = performTransitions(
        params,
        &stx,
        input,
    ) catch |e| {
        const test_vector_error = switch (e) {
            error.bad_slot => safrole_test_vector.ErrorCode.bad_slot,
            error.unexpected_ticket => safrole_test_vector.ErrorCode.unexpected_ticket,
            error.bad_ticket_order => safrole_test_vector.ErrorCode.bad_ticket_order,
            error.bad_ticket_proof => safrole_test_vector.ErrorCode.bad_ticket_proof,
            error.bad_ticket_attempt => safrole_test_vector.ErrorCode.bad_ticket_attempt,
            error.duplicate_ticket => safrole_test_vector.ErrorCode.duplicate_ticket,
            error.too_many_tickets_in_extrinsic => @panic("Unmapped error"),
            else => @panic("unmapped error"),
        };
        return .{
            .output = .{ .err = test_vector_error },
            .state = null,
        };
    };
    defer result.deinit(allocator);

    // merge the stx into
    try stx.takeBaseAndMerge();

    const test_vector_post_state = try JamStateToTestVectorState(
        params,
        allocator,
        &current_state,
    );

    return TransitionResult{
        .output = .{
            .ok = safrole_test_vector.OutputMarks{
                .epoch_mark = result.takeEpochMarker(),
                .tickets_mark = result.takeTicketMarker(),
            },
        },
        .state = test_vector_post_state,
    };
}

fn performTransitions(
    comptime params: Params,
    stx: *dstate.StateTransition(params),
    input: safrole_test_vector.Input,
) !safrole.Result {

    // Perform all transitions in sequence, propagating any errors
    try stf.transitionTime(params, stx, input.slot);
    try stf.transitionEta(params, stx, input.entropy);
    return try stf.transitionSafrole(
        params,
        stx,
        input.extrinsic,
    );
}

fn GammaFromTestVectorState(
    comptime validators_count: u32,
    comptime epoch_length: u32,
    allocator: Allocator,
    tvstate: safrole_test_vector.State,
) !state.Gamma(validators_count, epoch_length) {
    // Initialize with undefined since we'll set all fields
    var gamma: state.Gamma(validators_count, epoch_length) = undefined;

    // First safely copy gamma_k (BandersnatchPublic keys)
    gamma.k = try tvstate.gamma.gamma_k.deepClone(allocator);
    errdefer gamma.k.deinit(allocator);

    // Copy gamma_a (ticket accumulator)
    gamma.a = try allocator.dupe(types.TicketBody, tvstate.gamma.gamma_a);
    errdefer allocator.free(gamma.a);

    // Handle gamma_s union type
    switch (tvstate.gamma.gamma_s) {
        .tickets => |tickets| {
            gamma.s = .{
                .tickets = try allocator.dupe(types.TicketBody, tickets),
            };
            errdefer if (gamma.s == .tickets) allocator.free(gamma.s.tickets);
        },
        .keys => |keys| {
            gamma.s = .{
                .keys = try allocator.dupe(types.BandersnatchPublic, keys),
            };
            errdefer if (gamma.s == .keys) allocator.free(gamma.s.keys);
        },
    }

    // Copy gamma_z (bandersnatch ring root)
    gamma.z = tvstate.gamma.gamma_z;

    return gamma;
}

fn JamStateToTestVectorState(comptime params: Params, allocator: std.mem.Allocator, post_state: *const state.JamState(params)) !safrole_test_vector.State {
    // Create test vector state with gamma from jam state
    return safrole_test_vector.State{
        .gamma = .{
            .tau = post_state.tau.?,
            .eta = post_state.eta.?,
            .lambda = try post_state.lambda.?.deepClone(allocator),
            .kappa = try post_state.kappa.?.deepClone(allocator),
            .gamma_k = try post_state.gamma.?.k.deepClone(allocator),
            .iota = try post_state.iota.?.deepClone(allocator),
            .gamma_a = try allocator.dupe(types.TicketBody, post_state.gamma.?.a),
            .gamma_s = try post_state.gamma.?.s.deepClone(allocator),
            .gamma_z = post_state.gamma.?.z,
        },
        .post_offenders = try post_state.psi.?.offendersOwned(allocator),
    };
}
