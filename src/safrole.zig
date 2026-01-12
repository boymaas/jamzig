const std = @import("std");
const ArrayList = std.ArrayList;

const ring_vrf = @import("ring_vrf.zig");
const state_delta = @import("state_delta.zig");
const state = @import("state.zig");
pub const types = @import("types.zig");

pub const ticket_validation = @import("safrole/ticket_validation.zig");
pub const ordering = @import("safrole/ordering.zig");
pub const epoch_handler = @import("safrole/epoch_handler.zig");

const Params = @import("jam_params.zig").Params;
const StateTransition = state_delta.StateTransition;

const trace = @import("tracing").scoped(.safrole);
const tracy = @import("tracy");

pub const Error = error{
    /// Bad slot value.
    BadSlot,
    /// Received a ticket while in epoch's tail.
    UnexpectedTicket,
    /// Tickets must be sorted.
    BadTicketOrder,
    /// Invalid ticket ring proof.
    BadTicketProof,
    /// Invalid ticket attempt value.
    BadTicketAttempt,
    /// Reserved
    Reserved,
    /// Found a ticket duplicate.
    DuplicateTicket,
    /// Too many tickets in extrinsic
    TooManyTicketsInExtrinsic,
} || std.mem.Allocator.Error || ring_vrf.Error || state_delta.Error;

pub fn transition(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: Params,
    stx: *StateTransition(params),
    ticket_extrinsic: types.TicketsExtrinsic,
) Error!Result {
    const span = trace.span(@src(), .transition);
    defer span.deinit();
    span.debug("Starting state transition", .{});

    const verified_extrinsic = try ticket_validation.processTicketExtrinsic(
        IOExecutor,
        io_executor,
        params,
        stx,
        ticket_extrinsic,
    );
    defer stx.allocator.free(verified_extrinsic);

    if (stx.time.isNewEpoch()) {
        try epoch_handler.handleEpochTransition(
            params,
            stx,
        );
    }

    const gamma = try stx.ensure(.gamma);
    const gamma_prime: *state.Gamma(params.validators_count, params.epoch_length) = try stx.ensure(.gamma_prime);
    if (stx.time.isInTicketSubmissionPeriod()) {
        span.debug("Processing ticket submissions", .{});
        const merged_gamma_a = try mergeTicketsIntoTicketAccumulatorGammaA(
            stx.allocator,
            gamma_prime.a,
            verified_extrinsic,
            params.epoch_length,
        );
        stx.allocator.free(gamma_prime.a);
        gamma_prime.a = merged_gamma_a;
    }

    var epoch_marker: ?types.EpochMark = null;
    if (stx.time.isNewEpoch()) {
        const epoch_marker_span = span.child(@src(), .generate_epoch_marker);
        defer epoch_marker_span.deinit();
        const eta_prime = try stx.ensure(.eta_prime);
        epoch_marker = .{
            .entropy = eta_prime[1],
            .tickets_entropy = eta_prime[2],
            .validators = try gamma_prime.k
                .getEpochMarkValidatorsKeys(stx.allocator),
        };
    }

    var winning_ticket_marker: ?types.TicketsMark = null;
    if (stx.time.didCrossTicketSubmissionEndInSameEpoch() and
        gamma_prime.a.len == params.epoch_length)
    {
        const ticket_marker_span = span.child(@src(), .generate_ticket_marker);
        defer ticket_marker_span.deinit();
        winning_ticket_marker = .{
            .tickets = try ordering.outsideInOrdering(
                types.TicketBody,
                stx.allocator,
                gamma.a,
            ),
        };
    }

    return .{
        .epoch_marker = epoch_marker,
        .ticket_marker = winning_ticket_marker,
    };
}

fn mergeTicketsIntoTicketAccumulatorGammaA(
    allocator: std.mem.Allocator,
    gamma_a: []types.TicketBody,
    extrinsic: []types.TicketBody,
    epoch_length: u32,
) ![]types.TicketBody {
    const span = trace.span(@src(), .merge_tickets);
    defer span.deinit();
    span.debug("Merging tickets into accumulator gamma_a", .{});
    span.trace("Current gamma_a size: {d}, extrinsic size: {d}, epoch length: {d}", .{
        gamma_a.len,
        extrinsic.len,
        epoch_length,
    });

    const total_tickets = @min(
        gamma_a.len + extrinsic.len,
        epoch_length,
    );
    span.debug("Will merge {d} total tickets", .{total_tickets});
    var merged_tickets = try allocator.alloc(types.TicketBody, total_tickets);

    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;

    while (i < gamma_a.len and j < extrinsic.len and k < epoch_length) {
        if (std.mem.lessThan(u8, &gamma_a[i].id, &extrinsic[j].id)) {
            merged_tickets[k] = gamma_a[i];
            i += 1;
        } else {
            merged_tickets[k] = extrinsic[j];
            j += 1;
        }
        k += 1;
    }

    while (i < gamma_a.len and k < epoch_length) {
        merged_tickets[k] = gamma_a[i];
        i += 1;
        k += 1;
    }

    while (j < extrinsic.len and k < epoch_length) {
        merged_tickets[k] = extrinsic[j];
        j += 1;
        k += 1;
    }

    return merged_tickets;
}

pub const Result = struct {
    epoch_marker: ?types.EpochMark,
    ticket_marker: ?types.TicketsMark,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.epoch_marker) |*marker| {
            allocator.free(marker.validators);
        }
        if (self.ticket_marker) |*marker| {
            allocator.free(marker.tickets);
        }
        self.* = undefined;
    }

    /// Takes ownership of the epoch marker and sets it to null
    pub fn takeEpochMarker(self: *@This()) ?types.EpochMark {
        const marker = self.epoch_marker;
        self.epoch_marker = null;
        return marker;
    }

    /// Takes ownership of the ticket marker and sets it to null
    pub fn takeTicketMarker(self: *@This()) ?types.TicketsMark {
        const marker = self.ticket_marker;
        self.ticket_marker = null;
        return marker;
    }
};
