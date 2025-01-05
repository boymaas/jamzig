const std = @import("std");
const ArrayList = std.ArrayList;

const crypto = @import("../crypto.zig");
const ring_vrf = @import("../ring_vrf.zig");
const state_d = @import("../state_delta.zig");
pub const entropy = @import("../entropy.zig");
pub const state = @import("../state.zig");
pub const time = @import("../time.zig");
pub const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = state_d.StateTransition;

const trace = @import("../tracing.zig").scoped(.safrole);

const Error = @import("../safrole.zig").Error;

// Extracted ticket processing logic
pub fn processTicketExtrinsic(
    comptime params: Params,
    stx: *StateTransition(params),
    ticket_extrinsic: types.TicketsExtrinsic,
) Error![]types.TicketBody {
    const span = trace.span(.process_ticket_extrinsic);
    defer span.deinit();
    span.debug("Processing ticket extrinsic", .{});

    // in case we have no tickets leave early
    if (ticket_extrinsic.data.len == 0) {
        span.debug("No tickets in ticket extrinsic, leaving", .{});
        return &[_]types.TicketBody{};
    }

    // Process tickets if not in epoch's tail
    if (stx.time.current_slot_in_epoch >= params.ticket_submission_end_epoch_slot) {
        span.err("Received ticket extrinsic in epoch's tail", .{});
        return Error.unexpected_ticket;
    }

    // Chapter 6.7 Ticketing and extrensics
    // Check the number of ticket attempts in the input when more than N we have a bad ticket attempt
    for (ticket_extrinsic.data) |extrinsic| {
        if (extrinsic.attempt >= params.max_ticket_entries_per_validator) {
            std.debug.print("attempt {d}\n", .{extrinsic.attempt});
            return Error.bad_ticket_attempt;
        }
    }

    // We should not have more than K tickets in the input
    if (ticket_extrinsic.data.len > params.epoch_length) {
        return Error.too_many_tickets_in_extrinsic;
    }

    // Verify ticket envelope
    const gamma = try stx.ensure(.gamma);
    const eta_prime = try stx.ensure(.eta_prime);
    const verified_extrinsic = verifyTicketEnvelope(
        stx.allocator,
        params.validators_count,
        &gamma.z,
        eta_prime[2],
        ticket_extrinsic.data,
    ) catch |e| {
        if (e == error.SignatureVerificationFailed) {
            return Error.bad_ticket_proof;
        } else return e;
    };
    errdefer stx.allocator.free(verified_extrinsic);

    // Chapter 6.7: The tickets should be in order of their implied identifier
    var index: usize = 0;
    while (index < verified_extrinsic.len) : (index += 1) {
        const current_ticket = verified_extrinsic[index];

        // Check order and duplicates with previous ticket
        if (index > 0) {
            const order = std.mem.order(u8, &current_ticket.id, &verified_extrinsic[index - 1].id);
            switch (order) {
                .lt => return Error.bad_ticket_order,
                .eq => return Error.duplicate_ticket,
                .gt => {},
            }
        }

        // Check for duplicates in gamma_a using binary search
        std.debug.assert(blk: {
            if (gamma.a.len <= 1) break :blk true;
            var i: usize = 1;
            while (i < gamma.a.len) : (i += 1) {
                if (!std.mem.lessThan(u8, &gamma.a[i - 1].id, &gamma.a[i].id)) break :blk false;
            }
            break :blk true;
        });

        const position = std.sort.binarySearch(types.TicketBody, gamma.a, current_ticket, struct {
            fn order(context: types.TicketBody, item: types.TicketBody) std.math.Order {
                return std.mem.order(u8, &context.id, &item.id);
            }
        }.order);

        if (position != null) {
            span.warn("Found duplicate ticket ID: {s}", .{std.fmt.fmtSliceHexLower(&current_ticket.id)});
            span.trace("Current gamma_a contents:", .{});
            for (gamma.a, 0..) |ticket, idx| {
                span.trace("  [{d}] ID: {s}", .{ idx, std.fmt.fmtSliceHexLower(&ticket.id) });
            }
            return Error.duplicate_ticket;
        }
    }

    return verified_extrinsic;
}

fn verifyTicketEnvelope(
    allocator: std.mem.Allocator,
    ring_size: usize,
    gamma_z: *const types.BandersnatchVrfRoot,
    n2: types.Entropy,
    extrinsic: []const types.TicketEnvelope,
) ![]types.TicketBody {
    const span = trace.span(.verify_ticket_envelope);
    defer span.deinit();
    span.debug("Verifying {d} ticket envelopes", .{extrinsic.len});
    span.trace("Ring size: {d}, gamma_z: {any}, n2: {any}", .{
        ring_size,
        std.fmt.fmtSliceHexLower(gamma_z),
        std.fmt.fmtSliceHexLower(&n2),
    });

    // For now, map the extrinsic to the ticket setting the ticketbody.id to all 0s
    var tickets = try allocator.alloc(types.TicketBody, extrinsic.len);
    errdefer {
        span.debug("Cleanup after error - freeing tickets", .{});
        allocator.free(tickets);
    }

    const empty_aux_data = [_]u8{};

    for (extrinsic, 0..) |extr, i| {
        span.trace("Verifying ticket envelope [{d}]:", .{i});
        span.trace("  Attempt: {d}", .{extr.attempt});
        span.trace("  Signature: {s}", .{std.fmt.fmtSliceHexLower(&extr.signature)});

        // TODO: rewrite
        const vrf_input = "jam_ticket_seal" ++ n2 ++ [_]u8{extr.attempt};

        const output = try ring_vrf.verifyRingSignatureAgainstCommitment(
            gamma_z,
            ring_size,
            vrf_input,
            &empty_aux_data,
            &extr.signature,
        );
        span.trace("  VRF output (ticket ID): {s}", .{std.fmt.fmtSliceHexLower(&output)});

        tickets[i].attempt = extr.attempt;
        tickets[i].id = output;
    }

    return tickets;
}
