const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");

const jam_params = @import("../jam_params.zig");

// Re-Using test vectors JSON parsing to get GenesisJson state
const safrole_tv_types = @import("../tests/vectors/libs/safrole.zig");

const Gamma = struct {
    gamma_k: []safrole_tv_types.ValidatorData,
    gamma_a: []safrole_tv_types.TicketBody,
    gamma_s: safrole_tv_types.GammaS,
    gamma_z: safrole_tv_types.GammaZ,
};

const GenesisJson = struct {
    tau: u32,
    gamma: Gamma,
    eta: [4]safrole_tv_types.OpaqueHash,
    iota: []safrole_tv_types.ValidatorData,
    kappa: []safrole_tv_types.ValidatorData,
    lambda: []safrole_tv_types.ValidatorData,
};

pub fn buildGenesisState(comptime params: jam_params.Params, allocator: std.mem.Allocator, json_str: []const u8) !state.JamState(params) {
    var diagnostics = std.json.Diagnostics{};
    var scanner = std.json.Scanner.initCompleteInput(allocator, json_str);
    scanner.enableDiagnostics(&diagnostics);
    defer scanner.deinit();

    var parsed = std.json.parseFromTokenSource(GenesisJson, allocator, &scanner, .{ .ignore_unknown_fields = true, .parse_numbers = false }) catch |err| {
        std.debug.print("Could not parse genesis.json: {}\n{any}", .{ err, diagnostics });
        return err;
    };
    defer parsed.deinit();

    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // Copy validator data arrays
    try jam_state.initSafrole(allocator);

    jam_state.tau = parsed.value.tau;

    // Copy eta values
    var eta_items = &jam_state.eta.?;
    for (parsed.value.eta, 0..) |eta_hash, i| {
        eta_items[i] = eta_hash.bytes;
    }

    var gamma_k_items = jam_state.gamma.?.k.items();
    for (parsed.value.gamma.gamma_k, 0..) |validator, i| {
        gamma_k_items[i].bandersnatch = validator.bandersnatch.bytes;
        gamma_k_items[i].ed25519 = validator.ed25519.bytes;
        gamma_k_items[i].bls = validator.bls.bytes;
        gamma_k_items[i].metadata = validator.metadata.bytes;
    }

    var iota_items = jam_state.iota.?.items();
    for (parsed.value.iota, 0..) |validator, i| {
        iota_items[i].bandersnatch = validator.bandersnatch.bytes;
        iota_items[i].ed25519 = validator.ed25519.bytes;
        iota_items[i].bls = validator.bls.bytes;
        iota_items[i].metadata = validator.metadata.bytes;
    }

    var kappa_items = jam_state.kappa.?.items();
    for (parsed.value.kappa, 0..) |validator, i| {
        kappa_items[i].bandersnatch = validator.bandersnatch.bytes;
        kappa_items[i].ed25519 = validator.ed25519.bytes;
        kappa_items[i].bls = validator.bls.bytes;
        kappa_items[i].metadata = validator.metadata.bytes;
    }

    var lambda_items = jam_state.lambda.?.items();
    for (parsed.value.lambda, 0..) |validator, i| {
        lambda_items[i].bandersnatch = validator.bandersnatch.bytes;
        lambda_items[i].ed25519 = validator.ed25519.bytes;
        lambda_items[i].bls = validator.bls.bytes;
        lambda_items[i].metadata = validator.metadata.bytes;
    }

    // copyForwards gamma_a ticket bodies
    for (parsed.value.gamma.gamma_a, 0..) |ticket, i| {
        std.mem.copyForwards(u8, &jam_state.gamma.?.a[i].id, &ticket.id.bytes);
        jam_state.gamma.?.a[i].attempt = ticket.attempt;
    }

    // Copy gamma_s and gamma_z

    // free the memory of gamma.s first
    switch (jam_state.gamma.?.s) {
        .tickets => |t| allocator.free(t),
        .keys => |k| allocator.free(k),
    }
    jam_state.gamma.?.s = switch (parsed.value.gamma.gamma_s) {
        .tickets => |tickets| blk: {
            var converted = try allocator.alloc(types.TicketBody, tickets.len);
            for (tickets, 0..) |ticket, i| {
                converted[i] = .{
                    .id = ticket.id.bytes,
                    .attempt = ticket.attempt,
                };
            }
            break :blk .{ .tickets = converted };
        },
        .keys => |keys| blk: {
            var converted = try allocator.alloc(types.BandersnatchPublic, keys.len);
            for (keys, 0..) |key, i| {
                converted[i] = key.bytes;
            }
            break :blk .{ .keys = converted };
        },
    };
    std.mem.copyForwards(u8, &jam_state.gamma.?.z, &parsed.value.gamma.gamma_z.bytes);

    return jam_state;
}
