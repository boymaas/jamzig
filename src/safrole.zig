const std = @import("std");
const ArrayList = std.ArrayList;

const crypto = @import("crypto.zig");
const ring_vrf = @import("ring_vrf.zig");
const state_d = @import("state_delta.zig");
pub const entropy = @import("entropy.zig");
pub const jam_params = @import("jam_params.zig");
pub const state = @import("state.zig");
pub const time = @import("time.zig");
pub const types = @import("types.zig");

pub const ticket_validation = @import("safrole/ticket_validation.zig");
pub const ordering = @import("safrole/ordering.zig");
pub const epoch_handler = @import("safrole/epoch_handler.zig");

const Params = @import("jam_params.zig").Params;
const StateTransition = state_d.StateTransition;

const trace = @import("tracing.zig").scoped(.safrole);

pub const Error = error{
    /// Bad slot value.
    bad_slot,
    /// Received a ticket while in epoch's tail.
    unexpected_ticket,
    /// Tickets must be sorted.
    bad_ticket_order,
    /// Invalid ticket ring proof.
    bad_ticket_proof,
    /// Invalid ticket attempt value.
    bad_ticket_attempt,
    /// Reserved
    reserved,
    /// Found a ticket duplicate.
    duplicate_ticket,
    /// Too_many_tickets_in_extrinsic
    too_many_tickets_in_extrinsic,
} || std.mem.Allocator.Error || ring_vrf.Error || state_d.Error;

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

// Main transition function using extracted components
pub fn transition(
    comptime params: Params,
    stx: *StateTransition(params),
    ticket_extrinsic: types.TicketsExtrinsic,
) Error!Result {
    const span = trace.span(.transition);
    defer span.deinit();
    span.debug("Starting state transition", .{});

    // Process and validate ticket extrinsic
    const verified_extrinsic = try ticket_validation.processTicketExtrinsic(params, stx, ticket_extrinsic);
    defer stx.allocator.free(verified_extrinsic);

    // Handle epoch transition if needed
    if (stx.time.isNewEpoch()) {
        try epoch_handler.handleEpochTransition(
            params,
            stx.allocator,
            stx,
        );
    }

    // Acummulate tickets when within submission window
    const gamma = try stx.ensure(.gamma);
    const gamma_prime = try stx.ensure(.gamma_prime);
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

    // Generate markers
    var epoch_marker: ?types.EpochMark = null;
    if (stx.time.isNewEpoch()) {
        const eta_prime = try stx.ensure(.eta_prime);
        epoch_marker = .{
            .entropy = eta_prime[1],
            .tickets_entropy = eta_prime[2],
            .validators = try gamma_prime.k
                .getBandersnatchPublicKeys(stx.allocator),
        };
    }

    var winning_ticket_marker: ?types.TicketsMark = null;
    if (stx.time.isSameEpoch() and
        stx.time.didCrossTicketSubmissionEnd() and
        gamma_prime.a.len == params.epoch_length) // TODO: check if this should not be gamma_prime.a
    {
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

//  Merges the gamma_a and extrinsic tickets into a new ticket
// accumulator, limited by the epoch length.
fn mergeTicketsIntoTicketAccumulatorGammaA(
    allocator: std.mem.Allocator,
    gamma_a: []types.TicketBody,
    extrinsic: []types.TicketBody,
    epoch_length: u32,
) ![]types.TicketBody {
    const span = trace.span(.merge_tickets);
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
