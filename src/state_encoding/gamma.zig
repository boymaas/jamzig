const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const jam_params = @import("../jam_params.zig");

const trace = @import("tracing").scoped(.codec);

pub fn encode(
    comptime params: jam_params.Params,
    gamma: *const state.Gamma(params.validators_count, params.epoch_length),
    writer: anytype,
) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting gamma state encoding", .{});

    std.debug.assert(gamma.k.validators.len == params.validators_count);

    const validators_span = span.child(@src(), .validators);
    defer validators_span.deinit();
    validators_span.debug("Encoding {d} validators", .{gamma.k.validators.len});

    for (gamma.k.validators, 0..) |validator, i| {
        const validator_span = validators_span.child(@src(), .validator);
        defer validator_span.deinit();
        validator_span.debug("Encoding validator {d} of {d}", .{ i + 1, gamma.k.validators.len });
        validator_span.trace("Validator BLS key: {any}", .{std.fmt.fmtSliceHexLower(&validator.bls)});
        try codec.serialize(types.ValidatorData, params, writer, validator);
    }

    const vrf_span = span.child(@src(), .vrf_root);
    defer vrf_span.deinit();
    vrf_span.debug("Encoding VRF root", .{});
    vrf_span.trace("VRF root value: {any}", .{std.fmt.fmtSliceHexLower(&gamma.z)});
    try codec.serialize(types.BandersnatchVrfRoot, params, writer, gamma.z);

    const state_span = span.child(@src(), .state);
    defer state_span.deinit();

    switch (gamma.s) {
        .tickets => |tickets| {
            state_span.debug("Encoding tickets state", .{});
            try codec.writeInteger(0, writer);

            std.debug.assert(tickets.len == params.epoch_length);
            state_span.debug("Encoding {d} tickets", .{tickets.len});

            for (tickets, 0..) |ticket, i| {
                const ticket_span = state_span.child(@src(), .ticket);
                defer ticket_span.deinit();
                ticket_span.debug("Encoding ticket {d} of {d}", .{ i + 1, tickets.len });
                ticket_span.trace("Ticket ID: {any}, attempt: {d}", .{ std.fmt.fmtSliceHexLower(&ticket.id), ticket.attempt });
                try codec.serialize(types.TicketBody, params, writer, ticket);
            }
        },
        .keys => |keys| {
            state_span.debug("Encoding keys state", .{});
            try codec.writeInteger(1, writer);

            std.debug.assert(keys.len == params.epoch_length);
            state_span.debug("Encoding {d} keys", .{keys.len});

            for (keys, 0..) |key, i| {
                const key_span = state_span.child(@src(), .key);
                defer key_span.deinit();
                key_span.debug("Encoding key {d} of {d}", .{ i + 1, keys.len });
                key_span.trace("Key value: {any}", .{std.fmt.fmtSliceHexLower(&key)});
                try codec.serialize(types.BandersnatchPublic, params, writer, key);
            }
        },
    }

    const tickets_span = span.child(@src(), .tickets);
    defer tickets_span.deinit();
    tickets_span.debug("Encoding additional tickets array with {d} entries", .{gamma.a.len});
    try codec.serialize([]types.TicketBody, params, writer, gamma.a);
}

test "encode" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    var gamma = try state.Gamma(6, 12).init(allocator);
    defer gamma.deinit(allocator);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encode(jam_params.TINY_PARAMS, &gamma, buffer.writer());

    try testing.expect(buffer.items.len > 0);
}
