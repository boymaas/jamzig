const std = @import("std");

const types = @import("types.zig");
const jamstate = @import("state.zig");
const state_encoder = @import("state_encoding.zig");

const Params = @import("jam_params.zig").Params;

/// Constructs a 32-byte key with the input byte as the first element and zeros for the rest.
///
/// @param input - The byte to use as the first element of the key
/// @return A 32-byte array representing the key
fn constructSimpleByteKey(input: u8) [32]u8 {
    var result: [32]u8 = [_]u8{0} ** 32;
    result[0] = input;
    return result;
}

/// Constructs a 32-byte key using a byte and a service index.
/// The first byte is set to the input byte, followed by the 4-byte service index in little-endian format.
///
/// @param i - The byte to use as the first element of the key
/// @param s - The service index to encode in the key
/// @return A 32-byte array representing the key
fn constructByteServiceIndexKey(i: u8, s: u32) [32]u8 {
    var result: [32]u8 = [_]u8{0} ** 32;

    result[0] = i;
    std.mem.writeInt(u32, result[1..5], s, .little);
    return result;
}

/// Constructs a 32-byte key by interleaving a service index with a hash.
/// The service index bytes are interleaved with the first 4 bytes of the hash,
/// followed by the remaining 24 bytes of the hash.
///
/// @param s - The service index to encode in the key
/// @param h - A 32-byte hash to incorporate into the key
/// @return A 32-byte array representing the key
fn constructServiceIndexHashKey(s: u32, h: [32]u8) [32]u8 {
    var result: [32]u8 = [_]u8{0} ** 32;

    // Write service index in pieces
    var service_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &service_bytes, s, .little);

    // Interleave service bytes with hash
    result[0] = service_bytes[0];
    result[1] = h[0];
    result[2] = service_bytes[1];
    result[3] = h[1];
    result[4] = service_bytes[2];
    result[5] = h[2];
    result[6] = service_bytes[3];
    result[7] = h[3];

    // Copy remaining hash bytes
    std.mem.copyForwards(u8, result[8..], h[4..28]);
    return result;
}

/// Encodes data using the provided writer function and returns an owned slice.
fn encodeAndOwnSlice(
    allocator: std.mem.Allocator,
    encodeFn: anytype,
    encodeFnArgs: anytype,
) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const args = encodeFnArgs ++ .{buffer.writer()};
    try @call(.auto, encodeFn, args);
    return buffer.toOwnedSlice();
}

/// Function that takes a slice and converts it to
/// a fixed array of size
fn sliceToFixedArray(comptime size: usize, slice: []const u8) [size]u8 {
    std.debug.assert(slice.len == size);
    var result: [size]u8 = undefined;
    std.mem.copyForwards(u8, result[0..], slice[0..size]);
    return result;
}

/// Maps a state component to its encoding using the appropriate state key.
///
/// This function constructs a dictionary (hash map) where each key is a 32-byte array
/// representing a unique identifier for a state component, and each value is a byte slice
/// representing the encoded state component. The function uses different key construction
/// strategies depending on the type of state component being encoded.
///
/// @param allocator - The memory allocator to use for dynamic memory allocations
/// @param state - A pointer to the JamState structure containing the state components
/// @return A hash map where keys are 32-byte arrays and values are byte slices representing
///         the encoded state components. The function may return an error if memory allocation
///         fails or if encoding any state component fails.
pub const MerklizationDictionary = struct {
    entries: std.AutoHashMap([32]u8, []const u8),

    // FIX: move these entries to a shared type file
    const Entry = @import("merkle.zig").Entry;

    pub fn init(allocator: std.mem.Allocator) MerklizationDictionary {
        return .{
            .entries = std.AutoHashMap([32]u8, []const u8).init(allocator),
        };
    }

    /// Slice is owned, the values are owned by the dictionary.
    pub fn toOwnedSlice(self: *const MerklizationDictionary) ![]Entry {
        var buffer = std.ArrayList(Entry).init(self.entries.allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try buffer.append(.{ .k = entry.key_ptr.*, .v = entry.value_ptr.* });
        }

        return buffer.toOwnedSlice();
    }

    pub fn deinit(self: *MerklizationDictionary) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.entries.allocator.free(entry.*);
        }
        self.entries.deinit();
    }

    pub fn format(
        self: MerklizationDictionary,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try writer.print("key: {any}, value: {any}\n", .{
                std.fmt.fmtSliceHexLower(&entry.key_ptr.*),
                std.fmt.fmtSliceHexLower(entry.value_ptr.*[0..@min(entry.value_ptr.*.len, 160)]),
            });
        }
    }
};

pub fn buildStateMerklizationDictionary(
    comptime params: Params,
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState(params),
) !MerklizationDictionary {
    var map = std.AutoHashMap([32]u8, []const u8).init(allocator);
    errdefer map.deinit();

    // Helpers to ...
    const getOrInitManaged = @import("state_dictionary/utils.zig").getOrInitManaged;

    // Encode the simple state components using specific encoders
    {
        // Alpha (1)
        const alpha_key = constructSimpleByteKey(1);
        var alpha_managed = try getOrInitManaged(allocator, &state.alpha, .{});
        defer alpha_managed.deinit(allocator);
        const alpha_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodeAlpha,
            .{alpha_managed.ptr},
        );
        try map.put(alpha_key, alpha_value);

        // Phi (2)
        const phi_key = constructSimpleByteKey(2);
        var phi_managed = try getOrInitManaged(allocator, &state.phi, .{allocator});
        defer phi_managed.deinit(allocator);
        const phi_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodePhi,
            .{phi_managed.ptr},
        );
        try map.put(phi_key, phi_value);

        // Beta (3)
        const beta_key = constructSimpleByteKey(3);
        var beta_managed = try getOrInitManaged(allocator, &state.beta, .{ allocator, params.recent_history_size });
        defer beta_managed.deinit(allocator);
        const beta_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodeBeta,
            .{beta_managed.ptr},
        );
        try map.put(beta_key, beta_value);

        // Gamma (4)
        const gamma_key = constructSimpleByteKey(4);
        var gamma_managed = try getOrInitManaged(allocator, &state.gamma, .{ allocator, params.validators_count });
        defer gamma_managed.deinit(allocator);
        const gamma_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodeGamma,
            .{gamma_managed.ptr},
        );
        try map.put(gamma_key, gamma_value);

        // Psi (5)
        const psi_key = constructSimpleByteKey(5);
        var psi_managed = try getOrInitManaged(allocator, &state.psi, .{allocator});
        defer psi_managed.deinit(allocator);
        const psi_value = try encodeAndOwnSlice(allocator, state_encoder.encodePsi, .{psi_managed.ptr});
        try map.put(psi_key, psi_value);

        // Eta (6) does not contain allocations
        const eta_key = constructSimpleByteKey(6);
        const eta_managed = if (state.eta) |eta| eta else [_]types.Entropy{[_]u8{0} ** 32} ** 4;
        const eta_value = try encodeAndOwnSlice(allocator, state_encoder.encodeEta, .{&eta_managed});
        try map.put(eta_key, eta_value);

        // Iota (7)
        const iota_key = constructSimpleByteKey(7);
        var iota_managed = try getOrInitManaged(allocator, &state.iota, .{ allocator, params.validators_count });
        defer iota_managed.deinit(allocator);
        const iota_value = try encodeAndOwnSlice(allocator, state_encoder.encodeIota, .{iota_managed.ptr});
        try map.put(iota_key, iota_value);

        // Kappa (8)
        const kappa_key = constructSimpleByteKey(8);
        var kappa_managed = try getOrInitManaged(allocator, &state.kappa, .{ allocator, params.validators_count });
        defer kappa_managed.deinit(allocator);
        const kappa_value = try encodeAndOwnSlice(allocator, state_encoder.encodeKappa, .{kappa_managed.ptr});
        try map.put(kappa_key, kappa_value);

        // Lambda (9)
        const lambda_key = constructSimpleByteKey(9);
        var lambda_managed = try getOrInitManaged(allocator, &state.lambda, .{ allocator, params.validators_count });
        defer lambda_managed.deinit(allocator);
        const lambda_value = try encodeAndOwnSlice(allocator, state_encoder.encodeLambda, .{lambda_managed.ptr});
        try map.put(lambda_key, lambda_value);

        // Rho (10)
        const rho_key = constructSimpleByteKey(10);
        var rho_managed = try getOrInitManaged(allocator, &state.rho, .{});
        defer rho_managed.deinit(allocator);
        const rho_value = try encodeAndOwnSlice(allocator, state_encoder.encodeRho, .{rho_managed.ptr});
        try map.put(rho_key, rho_value);

        // Tau (11)
        const tau_key = constructSimpleByteKey(11);
        const tau_managed = if (state.tau) |tau| tau else 0; // stack managed
        const tau_value = try encodeAndOwnSlice(allocator, state_encoder.encodeTau, .{tau_managed});
        try map.put(tau_key, tau_value);

        // Chi (12)
        const chi_key = constructSimpleByteKey(12);
        var chi_managed = try getOrInitManaged(allocator, &state.chi, .{allocator});
        defer chi_managed.deinit(allocator);
        const chi_value = try encodeAndOwnSlice(allocator, state_encoder.encodeChi, .{chi_managed.ptr});
        try map.put(chi_key, chi_value);

        // Pi (13)
        const pi_key = constructSimpleByteKey(13);
        var pi_managed = try getOrInitManaged(allocator, &state.pi, .{ allocator, params.validators_count });
        defer pi_managed.deinit(allocator);
        const pi_value = try encodeAndOwnSlice(allocator, state_encoder.encodePi, .{pi_managed.ptr});
        try map.put(pi_key, pi_value);

        // Theta (14)
        const theta_key = constructSimpleByteKey(14);
        var theta_managed = try getOrInitManaged(allocator, &state.theta, .{allocator});
        defer theta_managed.deinit(allocator);
        const theta_value = try encodeAndOwnSlice(allocator, state_encoder.encodeTheta, .{theta_managed.ptr});
        try map.put(theta_key, theta_value);

        // Xi (15)
        const xi_key = constructSimpleByteKey(15);
        var xi_managed = try getOrInitManaged(allocator, &state.xi, .{allocator});
        defer xi_managed.deinit(allocator);
        // FIXME: now hard coded epoch size
        const xi_value = try encodeAndOwnSlice(allocator, state_encoder.encodeXi, .{ 12, allocator, &xi_managed.ptr.entries });
        try map.put(xi_key, xi_value);
    }

    // Handle delta component (service accounts) specially
    var delta_managed = try getOrInitManaged(allocator, &state.delta, .{allocator});
    defer delta_managed.deinit(allocator);
    if (delta_managed.ptr.accounts.count() > 0) {
        var service_iter = delta_managed.ptr.accounts.iterator();
        while (service_iter.next()) |service_entry| {
            const service_idx = service_entry.key_ptr.*;
            const account = service_entry.value_ptr;

            // Base account data
            const base_key = constructByteServiceIndexKey(255, service_idx);
            var base_value = std.ArrayList(u8).init(allocator);
            try state_encoder.delta.encodeServiceAccountBase(account, base_value.writer());

            try map.put(base_key, try base_value.toOwnedSlice());

            // Storage entries
            var storage_iter = account.storage.iterator();
            while (storage_iter.next()) |storage_entry| {
                const storage_key = constructServiceIndexHashKey(service_idx, storage_entry.key_ptr.*);
                try map.put(storage_key, storage_entry.value_ptr.*);
            }

            // Preimage lookups
            var preimage_iter = account.preimages.iterator();
            while (preimage_iter.next()) |preimage_entry| {
                const preimage_key = constructServiceIndexHashKey(service_idx, preimage_entry.key_ptr.*);
                try map.put(preimage_key, preimage_entry.value_ptr.*);
            }

            // Preimage timestamps
            var lookup_iter = account.preimage_lookups.iterator();
            while (lookup_iter.next()) |lookup_entry| {
                const delta_encoder = state_encoder.delta;

                // FIXME: use initCapacity
                var preimage_key = try std.ArrayList(u8).initCapacity(allocator, 32);
                try delta_encoder.encodePreimageKey(lookup_entry.key_ptr.*, preimage_key.writer());

                var preimage_lookup = try std.ArrayList(u8).initCapacity(allocator, 24);
                try delta_encoder.encodePreimageLookup(lookup_entry.value_ptr.*, preimage_lookup.writer());

                const lookup_key = constructServiceIndexHashKey(service_idx, sliceToFixedArray(32, try preimage_key.toOwnedSlice()));
                try map.put(lookup_key, try preimage_lookup.toOwnedSlice());
            }
        }
    }

    return .{ .entries = map };
}

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_
// | | | | '_ \| | __|| |/ _ \/ __| __|
// | |_| | | | | | |_ | |  __/\__ \ |_
//  \___/|_| |_|_|\__||_|\___||___/\__|

const testing = std.testing;

test "buildStateMerklizationDictionary" {
    const allocator = std.testing.allocator;
    const TINY = @import("jam_params.zig").TINY_PARAMS;

    var state = try jamstate.JamState(TINY).init(allocator);
    defer state.deinit(allocator);

    var map = try buildStateMerklizationDictionary(TINY, allocator, &state);
    defer map.deinit();
}

test "constructSimpleByteKey" {
    const key = constructSimpleByteKey(42);
    try testing.expectEqual(@as(u8, 42), key[0]);
    for (key[1..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "constructByteServiceIndexKey" {
    const key = constructByteServiceIndexKey(0xFF, 0x12345678);
    try testing.expectEqual(@as(u8, 0xFF), key[0]);
    try testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, key[1..5], .little));
    for (key[5..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "constructServiceIndexHashKey" {
    const service_index: u32 = 0x12345678;
    var hash: [32]u8 = [_]u8{0} ** 32;
    for (&hash, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    const key = constructServiceIndexHashKey(service_index, hash);

    try testing.expectEqual(@as(u8, 0x78), key[0]);
    try testing.expectEqual(@as(u8, 0x00), key[1]);
    try testing.expectEqual(@as(u8, 0x56), key[2]);
    try testing.expectEqual(@as(u8, 0x01), key[3]);
    try testing.expectEqual(@as(u8, 0x34), key[4]);
    try testing.expectEqual(@as(u8, 0x02), key[5]);
    try testing.expectEqual(@as(u8, 0x12), key[6]);
    try testing.expectEqual(@as(u8, 0x03), key[7]);

    try testing.expectEqualSlices(u8, hash[4..28], key[8..]);
}
