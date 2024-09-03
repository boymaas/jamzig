const std = @import("std");
const types = @import("../types.zig");

pub fn formatState(state: types.State, writer: anytype) !void {
    try writer.writeAll("State {\n");

    try writer.writeAll("\n---- Timeslot (τ) ----\n");
    try writer.print("  tau: {}\n", .{state.tau});

    try writer.writeAll("\n---- Entropy Accumulator (η) ----\n");
    try writer.writeAll("  eta: [\n");
    for (state.eta) |hash| {
        try writer.print("    0x{x}\n", .{std.fmt.fmtSliceHexLower(&hash)});
    }
    try writer.writeAll("  ]\n");

    try writer.writeAll("\n---- Previous Epoch Validators (λ) ----\n");
    try formatValidatorSlice(writer, "lambda", state.lambda);

    try writer.writeAll("\n---- Current Epoch Validators (κ) ----\n");
    try formatValidatorSlice(writer, "kappa", state.kappa);

    try writer.writeAll("\n---- Next Epoch Validators (γₖ) ----\n");
    try formatValidatorSlice(writer, "gamma_k", state.gamma_k);

    try writer.writeAll("\n---- Future Validators (ι) ----\n");
    try formatValidatorSlice(writer, "iota", state.iota);

    try writer.writeAll("\n---- Ticket Accumulator (γₐ) ----\n");
    try formatTicketSlice(writer, "gamma_a", state.gamma_a);

    try writer.writeAll("\n---- Sealing-key Sequence (γₛ) ----\n");
    try writer.writeAll("  gamma_s: ");
    switch (state.gamma_s) {
        .tickets => |tickets| {
            try writer.print("{} tickets\n", .{tickets.len});
            try formatTicketSlice(writer, "tickets", tickets);
        },
        .keys => |keys| {
            try writer.print("{} keys\n", .{keys.len});
            try formatKeySlice(writer, "keys", keys);
        },
    }

    try writer.writeAll("\n---- Bandersnatch Root (γ𝑧) ----\n");
    try writer.print("  gamma_z: 0x{x}\n", .{std.fmt.fmtSliceHexLower(&state.gamma_z)});

    // Calculate and print total validators
    const totalValidators = state.lambda.len + state.kappa.len + state.gamma_k.len + state.iota.len;
    try writer.writeAll("\n---- Total Validators ----\n");
    try writer.print("  {} validators\n", .{totalValidators});

    // Calculate and print total tickets and keys
    var totalTickets: usize = 0;
    var totalKeys: usize = 0;
    switch (state.gamma_s) {
        .tickets => |tickets| totalTickets = tickets.len,
        .keys => |keys| totalKeys = keys.len,
    }
    totalTickets += state.gamma_a.len;

    try writer.writeAll("\n---- Total Tickets and Keys ----\n");
    try writer.print("  {} tickets, {} keys\n", .{ totalTickets, totalKeys });

    try writer.writeAll("}\n");
}

fn formatTicketSlice(writer: anytype, name: []const u8, tickets: []const types.TicketBody) !void {
    try writer.print("  {s}: {} tickets\n", .{ name, tickets.len });
    for (tickets, 0..) |ticket, i| {
        try writer.print("    Ticket {}: id: 0x{x}, attempt: {}\n", .{ i, std.fmt.fmtSliceHexLower(&ticket.id), ticket.attempt });
    }
}

fn formatKeySlice(writer: anytype, name: []const u8, keys: []const types.BandersnatchKey) !void {
    try writer.print("  {s}: {} keys\n", .{ name, keys.len });
    for (keys, 0..) |key, i| {
        try writer.print("    Key {}: 0x{x}\n", .{ i, std.fmt.fmtSliceHexLower(&key) });
    }
}

fn formatValidatorSlice(writer: anytype, name: []const u8, validators: []const types.ValidatorData) !void {
    try writer.print("  {s}: {} validators\n", .{ name, validators.len });
    for (validators, 0..) |validator, i| {
        try writer.print("    Validator {}:\n", .{i});
        try writer.print("      bandersnatch: 0x{x}\n", .{std.fmt.fmtSliceHexLower(&validator.bandersnatch)});
        try writer.print("      ed25519: 0x{x}\n", .{std.fmt.fmtSliceHexLower(&validator.ed25519)});
        try writer.print("      bls: 0x{x}\n", .{std.fmt.fmtSliceHexLower(&validator.bls)});
        try writer.print("      metadata: 0x{x}\n", .{std.fmt.fmtSliceHexLower(&validator.metadata)});
    }
}
