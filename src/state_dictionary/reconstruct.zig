const std = @import("std");
const state = @import("../state.zig");
const state_decoding = @import("../state_decoding.zig");
const types = @import("../types.zig");
const MerklizationDictionary = @import("../state_dictionary.zig").MerklizationDictionary;
const Params = @import("../jam_params.zig").Params;

/// Reconstructs a JamState from a MerklizationDictionary by decoding its entries
pub fn reconstructState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    dict: *const MerklizationDictionary,
) !state.JamState(params) {
    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // Helper function to get reader for value
    const getReader = struct {
        fn get(value: []const u8) std.io.FixedBufferStream([]const u8).Reader {
            var stream = std.io.fixedBufferStream(value);
            return stream.reader();
        }
    }.get;

    // Iterate through all entries
    var it = dict.entries.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Check first byte to determine component
        switch (key[0]) {
            1 => { // Alpha
                jam_state.alpha = try state_decoding.alpha.decode(params.core_count, getReader(value));
            },
            2 => { // Phi
                jam_state.phi = try state_decoding.phi.decode(params.core_count, allocator, getReader(value));
            },
            3 => { // Beta
                jam_state.beta = try state_decoding.beta.decode(allocator, getReader(value));
            },
            4 => { // Gamma
                jam_state.gamma = try state_decoding.gamma.decode(params, allocator, getReader(value));
            },
            5 => { // Psi
                jam_state.psi = try state_decoding.psi.decode(allocator, getReader(value));
            },
            6 => { // Eta
                jam_state.eta = try state_decoding.eta.decode(getReader(value));
            },
            7 => { // Iota
                jam_state.iota = try state_decoding.iota.decode(allocator, params.validators_count, getReader(value));
            },
            8 => { // Kappa
                jam_state.kappa = try state_decoding.kappa.decode(allocator, params.validators_count, getReader(value));
            },
            9 => { // Lambda
                jam_state.lambda = try state_decoding.lambda.decode(allocator, params.validators_count, getReader(value));
            },
            10 => { // Rho
                jam_state.rho = try state_decoding.rho.decode(params, allocator, getReader(value));
            },
            11 => { // Tau
                jam_state.tau = try state_decoding.tau.decode(getReader(value));
            },
            12 => { // Chi
                jam_state.chi = try state_decoding.chi.decode(allocator, getReader(value));
            },
            13 => { // Pi
                jam_state.pi = try state_decoding.pi.decode(params.validators_count, getReader(value), allocator);
            },
            14 => { // Theta
                jam_state.theta = try state_decoding.theta.decode(params.epoch_length, allocator, getReader(value));
            },
            15 => { // Xi
                jam_state.xi = try state_decoding.xi.decode(params.epoch_length, allocator, getReader(value));
            },
            255 => { // Delta base
                // Delta requires special handling since it has multiple key types
                // TODO: Implement Delta reconstruction
                continue;
            },
            else => {
                // Check if key is for Delta storage/preimages
                if (key[0] >= 128) {
                    // TODO: Handle Delta storage/preimage entries
                    continue;
                }
                return error.UnknownStateComponent;
            },
        }
    }

    return jam_state;
}

test "reconstruct empty state" {
    const testing = std.testing;
    const TINY = @import("../jam_params.zig").TINY_PARAMS;

    var dict = MerklizationDictionary.init(testing.allocator);
    defer dict.deinit();

    var reconstructed = try reconstructState(TINY, testing.allocator, &dict);
    defer reconstructed.deinit(testing.allocator);

    // Verify all components are null in empty state
    try testing.expect(reconstructed.alpha == null);
    try testing.expect(reconstructed.beta == null);
    try testing.expect(reconstructed.gamma == null);
    try testing.expect(reconstructed.delta == null);
    try testing.expect(reconstructed.eta == null);
    try testing.expect(reconstructed.iota == null);
    try testing.expect(reconstructed.kappa == null);
    try testing.expect(reconstructed.lambda == null);
    try testing.expect(reconstructed.phi == null);
    try testing.expect(reconstructed.pi == null);
    try testing.expect(reconstructed.psi == null);
    try testing.expect(reconstructed.rho == null);
    try testing.expect(reconstructed.tau == null);
    try testing.expect(reconstructed.theta == null);
    try testing.expect(reconstructed.xi == null);
}

test "reconstruct state with components" {
    const testing = std.testing;
    const TINY = @import("../jam_params.zig").TINY_PARAMS;
    // const encoder = @import("../state_encoding.zig");

    // Create original state with some components
    var original = try state.JamState(TINY).init(testing.allocator);
    defer original.deinit(testing.allocator);

    // Initialize some components
    try original.initTau();
    try original.initEta();
    try original.initPhi(testing.allocator);

    // Create dictionary from original state
    var dict = try original.buildStateMerklizationDictionary(testing.allocator);
    defer dict.deinit();

    // Reconstruct state from dictionary
    var reconstructed = try reconstructState(TINY, testing.allocator, &dict);
    defer reconstructed.deinit(testing.allocator);

    // Verify reconstructed components match original
    try testing.expectEqual(original.tau, reconstructed.tau);
    try testing.expectEqual(original.eta, reconstructed.eta);
    try testing.expectEqual(original.phi, reconstructed.phi);
    // TODO: Add more component comparisons
}
