const std = @import("std");
const types = @import("../types.zig");

pub fn formatState(state: types.State, writer: anytype) !void {
    try writer.writeAll("State {\n");
    try writer.print("  tau: {}\n", .{state.tau});
    try writer.writeAll("  eta: [\n");
    for (state.eta) |hash| {
        try writer.print("    0x{x}\n", .{std.fmt.fmtSliceHexLower(&hash)});
    }
    try writer.writeAll("  ]\n");
    try formatValidatorSlice(writer, "lambda", state.lambda);
    try formatValidatorSlice(writer, "kappa", state.kappa);
    try formatValidatorSlice(writer, "gamma_k", state.gamma_k);
    try formatValidatorSlice(writer, "iota", state.iota);
    try writer.print("  gamma_a: {} tickets\n", .{state.gamma_a.len});
    for (state.gamma_a, 0..) |ticket, i| {
        try writer.print("    Ticket {}: id: 0x{x}, attempt: {}\n", .{ i, std.fmt.fmtSliceHexLower(&ticket.id), ticket.attempt });
    }
    try writer.writeAll("  gamma_s: ");
    switch (state.gamma_s) {
        .tickets => |tickets| {
            try writer.print("{} tickets\n", .{tickets.len});
            for (tickets, 0..) |ticket, i| {
                try writer.print("    Ticket {}: id: 0x{x}, attempt: {}\n", .{ i, std.fmt.fmtSliceHexLower(&ticket.id), ticket.attempt });
            }
        },
        .keys => |keys| {
            try writer.print("{} keys\n", .{keys.len});
            for (keys, 0..) |key, i| {
                try writer.print("    Key {}: 0x{x}\n", .{ i, std.fmt.fmtSliceHexLower(&key) });
            }
        },
    }
    try writer.print("  gamma_z: 0x{x}\n", .{std.fmt.fmtSliceHexLower(&state.gamma_z)});
    try writer.writeAll("}");
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
