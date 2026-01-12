const std = @import("std");
const ArrayList = std.ArrayList;

const ring_vrf = @import("../ring_vrf.zig");
const io = @import("../io.zig");

pub const entropy = @import("../entropy.zig");
pub const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const trace = @import("tracing").scoped(.safrole);

const Error = @import("../safrole.zig").Error;

pub fn processTicketExtrinsic(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    comptime params: Params,
    stx: *StateTransition(params),
    ticket_extrinsic: types.TicketsExtrinsic,
) Error![]types.TicketBody {
    const span = trace.span(@src(), .process_ticket_extrinsic);
    defer span.deinit();

    span.debug("Processing ticket extrinsic", .{});

    if (ticket_extrinsic.data.len == 0) {
        span.debug("No tickets in ticket extrinsic, leaving", .{});
        return &[_]types.TicketBody{};
    }

    if (stx.time.current_slot_in_epoch >= params.ticket_submission_end_epoch_slot) {
        span.err("Received ticket extrinsic in epoch's tail", .{});
        return Error.UnexpectedTicket;
    }

    // Chapter 6.7 Ticketing and extrensics
    for (ticket_extrinsic.data) |extrinsic| {
        if (extrinsic.attempt >= params.max_ticket_entries_per_validator) {
            return Error.BadTicketAttempt;
        }
    }

    if (ticket_extrinsic.data.len > params.epoch_length) {
        return Error.TooManyTicketsInExtrinsic;
    }

    const gamma = try stx.ensure(.gamma);
    const eta_prime = try stx.ensure(.eta_prime);
    const verified_extrinsic = verifyTicketEnvelope(
        IOExecutor,
        io_executor,
        stx.allocator,
        params.validators_count,
        &gamma.z,
        eta_prime[2],
        ticket_extrinsic.data,
    ) catch |e| {
        if (e == error.SignatureVerificationFailed) {
            return Error.BadTicketProof;
        } else return @errorCast(e);
    };
    errdefer stx.allocator.free(verified_extrinsic);

    // Chapter 6.7: The tickets should be in order of their implied identifier
    {
        const order_check_span = span.child(@src(), .check_order);
        defer order_check_span.deinit();
        var index: usize = 0;
        while (index < verified_extrinsic.len) : (index += 1) {
            const current_ticket = verified_extrinsic[index];

            if (index > 0) {
                const order = std.mem.order(u8, &current_ticket.id, &verified_extrinsic[index - 1].id);
                switch (order) {
                    .lt => return Error.BadTicketOrder,
                    .eq => return Error.DuplicateTicket,

                    .gt => {},
                }
            }

            {
                const duplicate_check_span = span.child(@src(), .check_duplicates);
                defer duplicate_check_span.deinit();
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
                    return Error.DuplicateTicket;
                }
            }
        }
    }

    return verified_extrinsic;
}

fn verifyTicketEnvelope(
    comptime IOExecutor: type,
    io_executor: *IOExecutor,
    allocator: std.mem.Allocator,
    ring_size: usize,
    gamma_z: *const types.BandersnatchVrfRoot,
    n2: types.Entropy,
    extrinsic: []const types.TicketEnvelope,
) ![]types.TicketBody {
    const span = trace.span(@src(), .verify_ticket_envelope);
    defer span.deinit();

    span.debug("Verifying {d} ticket envelopes", .{extrinsic.len});
    span.trace("Ring size: {d}, gamma_z: {any}, n2: {any}", .{
        ring_size,
        std.fmt.fmtSliceHexLower(gamma_z),
        std.fmt.fmtSliceHexLower(&n2),
    });

    var tickets = try allocator.alloc(types.TicketBody, extrinsic.len);
    errdefer {
        span.debug("Cleanup after error - freeing tickets", .{});
        allocator.free(tickets);
    }

    const empty_aux_data = [_]u8{};

    var task_group = io_executor.createGroup();
    defer task_group.deinit();

    for (extrinsic, 0..) |extr, i| {
        span.trace("Spawning VRF verification task [{d}]:", .{i});
        span.trace("  Attempt: {d}", .{extr.attempt});
        span.trace("  Signature: {s}", .{std.fmt.fmtSliceHexLower(&extr.signature)});

        try task_group.spawn(verifyTicketTask, .{
            gamma_z,
            ring_size,
            n2,
            extr,
            &tickets[i],
            &empty_aux_data,
        });
    }

    try task_group.waitAndCheckErrors();

    for (tickets, 0..) |ticket, i| {
        span.trace("VRF result [{d}] - ID: {s}", .{ i, std.fmt.fmtSliceHexLower(&ticket.id) });
    }

    return tickets;
}

fn verifyTicketTask(
    gamma_z: *const types.BandersnatchVrfRoot,
    ring_size: usize,
    n2: types.Entropy,
    extr: types.TicketEnvelope,
    output_ticket: *types.TicketBody,
    empty_aux_data: *const [0]u8,
) !void {
    const vrf_zone = trace.span(@src(), .verify_ticket_task);
    defer vrf_zone.deinit();

    const vrf_input = "jam_ticket_seal" ++ n2 ++ [_]u8{extr.attempt};

    const output = try ring_vrf.verifyRingSignatureAgainstCommitment(
        gamma_z,
        ring_size,
        vrf_input,
        empty_aux_data,
        &extr.signature,
    );

    output_ticket.attempt = extr.attempt;
    output_ticket.id = output;
}
