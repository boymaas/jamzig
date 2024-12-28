const std = @import("std");
const types = @import("../types.zig");
const jamstate = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

// Helper function to format validator information
fn formatValidatorSet(writer: anytype, validators: ?types.ValidatorSet, name: []const u8, symbol: []const u8) !void {
    if (validators) |set| {
        try writer.print("    {s} Validators ({s}): {d} validators\n", .{ name, symbol, set.validators.len });
        for (set.validators, 0..) |validator, i| {
            try writer.print("      {s}[{d}]: 0x{s}\n", .{
                symbol,
                i,
                std.fmt.fmtSliceHexLower(validator.bandersnatch[0..4]),
            });
        }
    }
}

// Helper function to format ticket information
fn formatTicket(writer: anytype, ticket: types.TicketBody, index: usize) !void {
    try writer.print("      Ticket[{d}]: ID=0x{s}, Attempt={d}\n", .{
        index,
        std.fmt.fmtSliceHexLower(ticket.id[0..4]),
        ticket.attempt,
    });
}

// Helper function to format public key information
fn formatPublicKey(writer: anytype, key: types.BandersnatchPublic, index: usize) !void {
    try writer.print("      Key[{d}]: 0x{s}\n", .{
        index,
        std.fmt.fmtSliceHexLower(key[0..4]),
    });
}

// Format state transition debug information to a writer
pub fn formatStateTransitionDebug(
    writer: anytype,
    comptime params: jam_params.Params,
    state: *const jamstate.JamState(params),
    block: *const types.Block,
) !void {
    try writer.print("\n▶ State Transition Debug\n", .{});

    const current_epoch = block.header.slot / params.epoch_length;
    const slot_in_epoch = block.header.slot % params.epoch_length;

    try writer.print("\n→ Time Information\n", .{});
    try writer.print("    Slot: {d}\n", .{block.header.slot});
    try writer.print("    Current Epoch: {d}\n", .{current_epoch});
    try writer.print("    Slot in Epoch: {d}\n", .{slot_in_epoch});
    try writer.print("    Block Author Index: {d}\n", .{block.header.author_index});

    try writer.print("\n→ Validator Sets\n", .{});
    try formatValidatorSet(writer, state.kappa, "Active", "κ");
    try formatValidatorSet(writer, state.iota, "Upcoming", "ι");
    try formatValidatorSet(writer, state.lambda, "Historical", "λ");

    try writer.print("\n→ Consensus State\n", .{});
    if (state.gamma) |gamma| {
        try formatValidatorSet(writer, gamma.k, "Active", "γk");

        try writer.print("    Consensus Mode (γs):\n", .{});
        switch (gamma.s) {
            .tickets => |tickets| {
                try writer.print("      Mode: Tickets (count: {d})\n", .{tickets.len});
                for (tickets, 0..) |ticket, i| {
                    try formatTicket(writer, ticket, i);
                }
            },
            .keys => |keys| {
                try writer.print("      Mode: Fallback Keys (count: {d})\n", .{keys.len});
                for (keys, 0..) |key, i| {
                    try formatPublicKey(writer, key, i);
                }
            },
        }
    }

    if (state.eta) |eta| {
        try writer.print("\n→ Entropy State (η)\n", .{});
        for (eta, 0..) |e, i| {
            try writer.print("    η[{d}]: 0x{s}...{s}\n", .{
                i,
                std.fmt.fmtSliceHexLower(e[0..4]),
                std.fmt.fmtSliceHexLower(e[28..32]),
            });
        }
    }
}

// Wrapper function to print to stderr
pub fn printStateTransitionDebug(
    comptime params: jam_params.Params,
    state: *const jamstate.JamState(params),
    block: *const types.Block,
) void {
    formatStateTransitionDebug(std.io.getStdErr().writer(), params, state, block) catch return;
}
