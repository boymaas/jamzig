const std = @import("std");
const types = @import("../types.zig");
const jamstate = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

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

fn formatTicket(writer: anytype, ticket: types.TicketBody, index: usize) !void {
    try writer.print("      Ticket[{d}]: ID=0x{s}, Attempt={d}\n", .{
        index,
        std.fmt.fmtSliceHexLower(ticket.id[0..4]),
        ticket.attempt,
    });
}

fn formatPublicKey(writer: anytype, key: types.BandersnatchPublic, index: usize) !void {
    try writer.print("      Key[{d}]: 0x{s}\n", .{
        index,
        std.fmt.fmtSliceHexLower(key[0..4]),
    });
}

pub fn formatStateDebug(
    writer: anytype,
    comptime params: jam_params.Params,
    state: *const jamstate.JamState(params),
) !void {
    try writer.print("\n▶ State Debug\n", .{});

    try writer.print("\n→ Validator Sets \n", .{});
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
}

fn formatBlockHeaderDebug(
    writer: anytype,
    comptime params: jam_params.Params,
    block: *const types.Block,
) !void {
    const block_hash = try block.header.header_hash(params, std.heap.page_allocator);
    try writer.print("▶ Block: S#{d:0>4}({d:0>3}/{d:0>3}) author={d:0>4} hash={s} pstate={s} seal={s}", .{
        block.header.slot,
        block.header.slot % params.epoch_length,
        block.header.slot / params.epoch_length,
        block.header.author_index,
        std.fmt.fmtSliceHexLower(block_hash[0..2]),
        std.fmt.fmtSliceHexLower(block.header.parent_state_root[0..2]),
        std.fmt.fmtSliceHexLower(block.header.seal[0..2]),
    });
}

pub fn formatBlockDebug(
    writer: anytype,
    comptime params: jam_params.Params,
    block: *const types.Block,
) !void {
    try formatBlockHeaderDebug(writer, params, block);
    try writer.print("\n", .{});
}

// Format block debug information with entropy from state
pub fn formatBlockEntropyDebug(
    writer: anytype,
    comptime params: jam_params.Params,
    block: *const types.Block,
    state: *const jamstate.JamState(params),
) !void {
    try formatBlockHeaderDebug(writer, params, block);

    if (state.eta) |eta| {
        try writer.print(" η=[", .{});
        for (eta[0..@min(4, eta.len)], 0..) |e, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{s}", .{std.fmt.fmtSliceHexLower(e[0..2])});
        }
        try writer.print("]", .{});
    }

    if (state.gamma) |gamma| {
        switch (gamma.s) {
            .tickets => |tickets| try writer.print(" γs=tickets({d})", .{tickets.len}),
            .keys => |keys| try writer.print(" γs=keys({d})", .{keys.len}),
        }
        try writer.print(" acc={d:0>4}", .{gamma.a.len});
        try writer.print(" vrf={s}", .{std.fmt.fmtSliceHexLower(gamma.z[0..4])});
    }
    try writer.print("\n", .{});
}

pub fn formatStateTransitionDebug(
    writer: anytype,
    comptime params: jam_params.Params,
    state: *const jamstate.JamState(params),
    block: *const types.Block,
) !void {
    try formatBlockDebug(writer, params, block);
    try formatStateDebug(writer, params, state);
}

pub fn printStateDebug(
    comptime params: jam_params.Params,
    state: *const jamstate.JamState(params),
) void {
    formatStateDebug(std.io.getStdErr().writer(), params, state) catch return;
}

pub fn printBlockDebug(
    comptime params: jam_params.Params,
    block: *const types.Block,
) void {
    formatBlockDebug(std.io.getStdErr().writer(), params, block) catch return;
}

pub fn printBlockEntropyDebug(
    comptime params: jam_params.Params,
    block: *const types.Block,
    state: *const jamstate.JamState(params),
) void {
    formatBlockEntropyDebug(std.io.getStdErr().writer(), params, block, state) catch return;
}

pub fn printStateTransitionDebug(
    comptime params: jam_params.Params,
    state: *const jamstate.JamState(params),
    block: *const types.Block,
) void {
    formatStateTransitionDebug(std.io.getStdErr().writer(), params, state, block) catch return;
}

// Variants that return allocated strings
pub fn allocPrintStateDebug(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState(params),
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try formatStateDebug(list.writer(), params, state);
    return list.toOwnedSlice();
}

pub fn allocPrintBlockDebug(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    block: *const types.Block,
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try formatBlockDebug(list.writer(), params, block);
    return list.toOwnedSlice();
}

pub fn formatEntropyDebug(writer: anytype, eta: types.EntropyBuffer) !void {
    try writer.print("\n→ Entropy State (η)\n", .{});
    for (eta, 0..) |e, i| {
        try writer.print("    η[{d}]: 0x{s}...{s}\n", .{
            i,
            std.fmt.fmtSliceHexLower(e[0..4]),
            std.fmt.fmtSliceHexLower(e[28..32]),
        });
    }
}

pub fn printEntropyDebug(eta: types.EntropyBuffer) void {
    formatEntropyDebug(std.io.getStdErr().writer(), eta) catch return;
}

pub fn allocPrintEntropyDebug(
    allocator: std.mem.Allocator,
    eta: types.EntropyBuffer,
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try formatEntropyDebug(list.writer(), eta);
    return list.toOwnedSlice();
}

pub fn allocPrintStateTransitionDebug(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState(params),
    block: *const types.Block,
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try formatStateTransitionDebug(list.writer(), params, state, block);
    return list.toOwnedSlice();
}
