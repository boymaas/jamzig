const std = @import("std");
const testing = std.testing;

const stf = @import("stf.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const codec = @import("codec.zig");

const jam_params = @import("jam_params.zig");

const SlurpedFile = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,

    pub fn deinit(self: *SlurpedFile) void {
        self.allocator.free(self.buffer);
    }
};

fn slurpBin(allocator: std.mem.Allocator, path: []const u8) !SlurpedFile {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    return SlurpedFile{
        .allocator = allocator,
        .buffer = buffer,
    };
}

// Re-Using test vectors JSON parsing to get GenesisJson state
const safrole_tv_types = @import("tests/vectors/libs/safrole.zig");

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

fn buildGenesisState(comptime params: jam_params.Params, allocator: std.mem.Allocator, json_str: []const u8) !state.JamState(params) {
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

test "jamtestnet: block import" {
    // Get test allocator
    const allocator = testing.allocator;

    // Get ordered block files
    var jam_state = try buildGenesisState(jam_params.TINY_PARAMS, allocator, @embedFile("stf_test/genesis.json"));
    defer jam_state.deinit(allocator);

    // src/stf_test/jamtestnet/traces/safrole/
    // src/stf_test/jamtestnet/traces/safrole/jam_duna
    // src/stf_test/jamtestnet/traces/safrole/jam_duna/traces
    // src/stf_test/jamtestnet/traces/safrole/jam_duna/state_snapshots0

    const base_path = "src/stf_test/jamtestnet/traces/safrole/jam_duna/blocks";
    const getOrderedFiles = @import("tests/ordered_files.zig").getOrderedFiles;
    var trace_files = try getOrderedFiles(allocator, base_path);
    defer trace_files.deinit();
    // generate the block file from epoch 373496..=373500 and and for each of
    // those number 0..12 epochs
    // iterate the epochs
    std.debug.print("\n", .{});
    for (trace_files.items()) |trace_file| {
        // we are only insterested in the bin files
        if (!std.mem.endsWith(u8, trace_file, ".bin")) {
            continue;
        }

        std.debug.print("deserializing {s}\n", .{trace_file});

        // Slurp the binary file
        var slurped = try slurpBin(allocator, trace_file);
        defer slurped.deinit();

        // Now decode the block
        const block = try codec.deserialize(types.Block, jam_params.TINY_PARAMS, allocator, slurped.buffer);
        defer block.deinit();

        std.debug.print("block {}\n", .{block.value.header.slot});

        var new_state = try stf.stateTransition(jam_params.TINY_PARAMS, allocator, &jam_state, &block.value);
        defer new_state.deinit(allocator);

        try jam_state.merge(&new_state, allocator);
    }
    // NOTE: there is one more 373500_0.bin which we can do later

    // Perform state transition
    // var new_state = try stf.stateTransition(allocator, TINY_PARAMS, &initial_state, test_block);
    // defer new_state.deinit();

}
