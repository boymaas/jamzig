const std = @import("std");

const types = @import("types.zig");
const jamstate = @import("state.zig");
const state_encoder = @import("state_encoding.zig");
const state_keys = @import("state_keys.zig");

pub const reconstruct = @import("state_dictionary/reconstruct.zig");

const Params = @import("jam_params.zig").Params;

//  _  __             ____                _                   _   _
// | |/ /___ _   _   / ___|___  _ __  ___| |_ _ __ _   _  ___| |_(_) ___  _ __
// | ' // _ \ | | | | |   / _ \| '_ \/ __| __| '__| | | |/ __| __| |/ _ \| '_ \
// | . \  __/ |_| | | |__| (_) | | | \__ \ |_| |  | |_| | (__| |_| | (_) | | | |
// |_|\_\___|\__, |  \____\___/|_| |_|___/\__|_|   \__,_|\___|\__|_|\___/|_| |_|
//           |___/
//
// REFACTORED: All key construction functions moved to state_keys.zig
// This module now imports and uses centralized key construction.

//  _  __            __  __                   _ _
// | |/ /___ _   _  |  \/  | __ _ _ __   __ _| (_)_ __   __ _
// | ' // _ \ | | | | |\/| |/ _` | '_ \ / _` | | | '_ \ / _` |
// | . \  __/ |_| | | |  | | (_| | | | | (_| | | | | | | (_| |
// |_|\_\___|\__, | |_|  |_|\__,_|_| |_|\__, |_|_|_| |_|\__, |
//           |___/                      |___/           |___/

//// Represents the different types of keys in the state dictionary
pub const DictKeyType = enum {
    delta_storage, // Service storage entries
    delta_preimage, // Service preimage entries
    delta_preimage_lookup, // Service preimage lookup entries
};

// REFACTORED: LossyHash type removed - no longer needed with structured 31-byte keys

// REFACTORED: All legacy key building functions removed
// Key construction now centralized in state_keys.zig

const services = @import("services.zig");

// TEMPORARY: Compatibility functions for transitional phase
// These will be removed when ServiceAccount is updated to use structured keys

/// Temporary compatibility function for hash-based storage keys
/// Will be removed when ServiceAccount uses structured 31-byte keys
fn constructServiceIndexHashKey(s: u32, h: [32]u8) types.StateKey {
    // Use the new preimage key construction as a temporary compatibility layer
    return state_keys.constructServicePreimageKey(s, h);
}

/// Temporary compatibility function for preimage lookup keys
/// Will be removed when ServiceAccount uses structured 31-byte keys  
// buildPreimageLookupKey function removed - we now use StateKey directly

//  _   _ _   _ _
// | | | | |_(_) |___
// | | | | __| | / __|
// | |_| | |_| | \__ \
//  \___/ \__|_|_|___/
//

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

//  ____  _  __  __
// |  _ \(_)/ _|/ _|
// | | | | | |_| |_
// | |_| | |  _|  _|
// |____/|_|_| |_|
//

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
pub const DiffType = enum {
    added,
    removed,
    changed,
};

pub const DiffEntry = struct {
    key: types.StateKey,
    diff_type: DiffType,
    me_value: ?[]const u8 = null,
    other_value: ?[]const u8 = null,

    pub fn format(
        self: DiffEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
        allocator: std.mem.Allocator,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s} key: {s}", .{
            @tagName(self.diff_type),
            std.fmt.fmtSliceHexLower(&self.key),
        });

        switch (self.diff_type) {
            .added => try writer.print(", value(len={d}): {s}", .{
                self.other_value.?.len,
                std.fmt.fmtSliceHexLower(self.other_value.?[0..@min(self.other_value.?.len, 160)]),
            }),
            .removed => try writer.print(", value(len={d}): {s}", .{
                self.me_value.?.len,
                std.fmt.fmtSliceHexLower(self.me_value.?[0..@min(self.me_value.?.len, 160)]),
            }),
            .changed => {
                try writer.print("\n", .{});
                try writer.print("me(len={d}):     other(len={d}):\n", .{ self.me_value.?.len, self.other_value.?.len });

                const old_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(self.me_value.?)});
                defer allocator.free(old_hex);
                const new_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(self.other_value.?)});
                defer allocator.free(new_hex);

                var i: usize = 0;
                while (i < @max(old_hex.len, new_hex.len)) : (i += 64) {
                    const old_chunk = if (i < old_hex.len) old_hex[i..@min(i + 64, old_hex.len)] else "";
                    const new_chunk = if (i < new_hex.len) new_hex[i..@min(i + 64, new_hex.len)] else "";

                    // Print old chunk with potential highlighting
                    var j: usize = 0;
                    while (j < 64) : (j += 1) {
                        const old_char = if (j < old_chunk.len) old_chunk[j] else ' ';
                        const new_char = if (j < new_chunk.len) new_chunk[j] else ' ';

                        if (old_char != new_char) {
                            try writer.writeAll("\x1b[33m"); // Yellow
                            try writer.writeByte(old_char);
                            try writer.writeAll("\x1b[0m"); // Reset
                        } else {
                            try writer.writeByte(old_char);
                        }
                    }

                    try writer.writeAll("  "); // Separator

                    // Print new chunk with potential highlighting
                    j = 0;
                    while (j < 64) : (j += 1) {
                        const old_char = if (j < old_chunk.len) old_chunk[j] else ' ';
                        const new_char = if (j < new_chunk.len) new_chunk[j] else ' ';

                        if (old_char != new_char) {
                            try writer.writeAll("\x1b[33m"); // Yellow
                            try writer.writeByte(new_char);
                            try writer.writeAll("\x1b[0m"); // Reset
                        } else {
                            try writer.writeByte(new_char);
                        }
                    }
                    try writer.writeByte('\n');
                }
            },
        }
        try writer.writeByte('\n');
    }
};

pub const MerklizationDictionaryDiff = struct {
    entries: std.ArrayList(DiffEntry),

    pub fn init(allocator: std.mem.Allocator) MerklizationDictionaryDiff {
        return .{
            .entries = std.ArrayList(DiffEntry).init(allocator),
        };
    }

    pub fn items(self: *const MerklizationDictionaryDiff) []DiffEntry {
        self.entries.items;
    }

    // TODO: camelCase
    pub fn has_changes(self: *const MerklizationDictionaryDiff) bool {
        return self.entries.items.len > 0;
    }

    pub fn deinit(self: *MerklizationDictionaryDiff) void {
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn format(
        self: MerklizationDictionaryDiff,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        for (self.entries.items) |entry| {
            try entry.format(fmt, options, writer, self.entries.allocator);
        }
    }
};

//  __  __           _    _      ____  _      _
// |  \/  | ___ _ __| | _| | ___|  _ \(_) ___| |_
// | |\/| |/ _ \ '__| |/ / |/ _ \ | | | |/ __| __|
// | |  | |  __/ |  |   <| |  __/ |_| | | (__| |_
// |_|  |_|\___|_|  |_|\_\_|\___|____/|_|\___|\__|
//

// Metadata for state components
pub const StateComponentMetadata = struct {
    component_index: u8, // 1-15 for state components
};

// Metadata for service base info
pub const DeltaBaseMetadata = struct {
    service_index: u32,
};

// Metadata for storage entries
pub const DeltaStorageMetadata = struct {
    storage_key: types.StateKey, // [31]u8 to match ServiceAccount.storage
};

// Metadata for preimage entries
pub const DeltaPreimageMetadata = struct {
    hash: [32]u8,
    preimage_length: u32,
};

// Metadata for preimage lookup entries
pub const DeltaPreimageLookupMetadata = struct {
    hash: [32]u8,
    preimage_length: u32,
};

// Union of all possible metadata types
pub const DictMetadata = union(DictKeyType) {
    delta_storage: DeltaStorageMetadata,
    delta_preimage: DeltaPreimageMetadata,
    delta_preimage_lookup: DeltaPreimageLookupMetadata,
};

// Enhanced dictionary entry with metadata
pub const DictEntry = struct {
    key: types.StateKey,
    value: []const u8,
    metadata: ?DictMetadata = null,

    pub fn deepClone(self: *const DictEntry, allocator: std.mem.Allocator) !DictEntry {
        return DictEntry{
            .key = self.key,
            .value = try allocator.dupe(u8, self.value),
            .metadata = self.metadata,
        };
    }

    pub fn deinit(self: *DictEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const MerklizationDictionary = struct {
    entries: std.AutoHashMap(types.StateKey, DictEntry),

    // FIX: move these entries to a shared type file
    pub const MerkleEntry = @import("merkle.zig").Entry;

    pub fn init(allocator: std.mem.Allocator) MerklizationDictionary {
        return .{
            .entries = std.AutoHashMap(types.StateKey, DictEntry).init(allocator),
        };
    }

    /// Calculate the state root for this dict
    pub fn buildStateRoot(self: *const MerklizationDictionary, allocator: std.mem.Allocator) !types.StateRoot {
        return try @import("state_merklization.zig").merklizeStateDictionary(allocator, self);
    }

    /// Slice is owned, the values are owned by the dictionary.
    pub fn toOwnedSlice(self: *const MerklizationDictionary) ![]MerkleEntry {
        var buffer = std.ArrayList(MerkleEntry).init(self.entries.allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try buffer.append(.{ .k = entry.key_ptr.*, .v = entry.value_ptr.value });
        }

        return buffer.toOwnedSlice();
    }

    /// Returns a new owned slice of entries sorted by key.
    /// The slice should be freed by the caller.
    /// The values remain owned by the dictionary.
    pub fn toOwnedSliceSortedByKey(self: *const MerklizationDictionary) ![]MerkleEntry {
        const slice = try self.toOwnedSlice();
        const Context = struct {
            pub fn lessThan(_: @This(), a: MerkleEntry, b: MerkleEntry) bool {
                return std.mem.lessThan(u8, &a.k, &b.k);
            }
        };
        std.mem.sort(MerkleEntry, slice, Context{}, Context.lessThan);
        return slice;
    }

    /// Puts an DictEntry in the dictionary, deallocates an existing one
    /// takes ownership of the entry
    pub fn put(self: *MerklizationDictionary, entry: DictEntry) !void {
        // Put or replace the entry
        if (try self.entries.fetchPut(entry.key, entry)) |existing| {
            @constCast(&existing.value).deinit(self.entries.allocator);
        }
    }

    pub fn deinit(self: *MerklizationDictionary) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            entry.deinit(self.entries.allocator);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// Compare this dictionary with another and return their differences
    pub fn diff(self: *const MerklizationDictionary, other: *const MerklizationDictionary) !MerklizationDictionaryDiff {
        var result = MerklizationDictionaryDiff.init(self.entries.allocator);
        errdefer result.deinit();

        // Check for added and changed entries
        var other_it = other.entries.iterator();
        while (other_it.next()) |other_entry| {
            const key = other_entry.key_ptr.*;
            const new_value = other_entry.value_ptr.*;

            if (self.entries.get(key)) |me_entry| {
                // Entry exists in both - check if changed
                if (!std.mem.eql(u8, me_entry.value, new_value.value)) {
                    try result.entries.append(.{
                        .key = key,
                        .diff_type = .changed,
                        .me_value = me_entry.value,
                        .other_value = new_value.value,
                    });
                }
            } else {
                // Entry only in other - added
                try result.entries.append(.{
                    .key = key,
                    .diff_type = .added,
                    .other_value = new_value.value,
                });
            }
        }

        // Check for removed entries
        var self_it = self.entries.iterator();
        while (self_it.next()) |self_entry| {
            const key = self_entry.key_ptr.*;
            // const old_value = self_entry.value_ptr.*;

            if (!other.entries.contains(key)) {
                try result.entries.append(.{
                    .key = key,
                    .diff_type = .removed,
                    .me_value = self_entry.value_ptr.*.value,
                });
            }
        }

        return result;
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
            try writer.print("type: {s}, key: {s}, ", .{
                @tagName(entry.value_ptr.metadata),
                std.fmt.fmtSliceHexLower(&entry.key_ptr.*),
            });

            // Format metadata based on type
            switch (entry.value_ptr.metadata) {
                .state_component => |m| try writer.print("component: {d}, ", .{m.component_index}),
                .delta_base => |m| try writer.print("service: {d}, ", .{m.service_index}),
                .delta_storage => |m| try writer.print("service: {d}, ", .{m.service_index}),
                .delta_preimage => |m| try writer.print("service: {d}, ", .{m.service_index}),
                .delta_preimage_lookup => |m| try writer.print("service: {d}, ", .{m.service_index}),
                .unknown => {},
            }

            try writer.print("value: {s}\n", .{
                std.fmt.fmtSliceHexLower(entry.value_ptr.value[0..@min(entry.value_ptr.value.len, 160)]),
            });
        }
    }
};

pub const DictionaryConfig = struct {
    include_preimage_timestamps: bool = true,
    include_preimages: bool = true,
    include_storage: bool = true,
};

/// Uses a config to conditionally enable or disable certain parts of the
/// building process.
pub fn buildStateMerklizationDictionaryWithConfig(
    comptime params: Params,
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState(params),
    comptime config: DictionaryConfig,
) !MerklizationDictionary {
    var map = std.AutoHashMap(types.StateKey, DictEntry).init(allocator);
    errdefer map.deinit();

    // Helpers to ...
    const getOrInitManaged = @import("state_dictionary/utils.zig").getOrInitManaged;

    // Encode the simple state components using specific encoders
    {
        // Alpha (1)
        const alpha_key = state_keys.constructStateComponentKey(1);
        var alpha_managed = try getOrInitManaged(allocator, &state.alpha, .{});
        defer alpha_managed.deinit(allocator);
        const alpha_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodeAlpha,
            .{ params.core_count, params.max_authorizations_pool_items, alpha_managed.ptr },
        );
        try map.put(alpha_key, .{
            .key = alpha_key,
            .value = alpha_value,
        });

        // Phi (2)
        const phi_key = state_keys.constructStateComponentKey(2);
        var phi_managed = try getOrInitManaged(allocator, &state.phi, .{allocator});
        defer phi_managed.deinit(allocator);
        const phi_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodePhi,
            .{phi_managed.ptr},
        );
        try map.put(phi_key, .{
            .key = phi_key,
            .value = phi_value,
        });

        // Beta (3)
        const beta_key = state_keys.constructStateComponentKey(3);
        var beta_managed = try getOrInitManaged(allocator, &state.beta, .{ allocator, params.recent_history_size });
        defer beta_managed.deinit(allocator);
        const beta_value = try encodeAndOwnSlice(
            allocator,
            state_encoder.encodeBeta,
            .{beta_managed.ptr},
        );
        try map.put(beta_key, .{
            .key = beta_key,
            .value = beta_value,
        });

        // Gamma (4)
        const gamma_key = state_keys.constructStateComponentKey(4);
        var gamma_managed = try getOrInitManaged(allocator, &state.gamma, .{allocator});
        defer gamma_managed.deinit(allocator);
        var gamma_buffer = std.ArrayList(u8).init(allocator);
        try state_encoder.encodeGamma(params, gamma_managed.ptr, gamma_buffer.writer());
        const gamma_value = try gamma_buffer.toOwnedSlice();
        try map.put(gamma_key, .{
            .key = gamma_key,
            .value = gamma_value,
        });

        // Psi (5)
        const psi_key = state_keys.constructStateComponentKey(5);
        var psi_managed = try getOrInitManaged(allocator, &state.psi, .{allocator});
        defer psi_managed.deinit(allocator);
        const psi_value = try encodeAndOwnSlice(allocator, state_encoder.encodePsi, .{psi_managed.ptr});
        try map.put(psi_key, .{
            .key = psi_key,
            .value = psi_value,
        });

        // Eta (6) does not contain allocations
        const eta_key = state_keys.constructStateComponentKey(6);
        const eta_managed = if (state.eta) |eta| eta else [_]types.Entropy{[_]u8{0} ** 32} ** 4;
        const eta_value = try encodeAndOwnSlice(allocator, state_encoder.encodeEta, .{&eta_managed});
        try map.put(eta_key, .{
            .key = eta_key,
            .value = eta_value,
        });

        // Iota (7)
        const iota_key = state_keys.constructStateComponentKey(7);
        var iota_managed = try getOrInitManaged(allocator, &state.iota, .{ allocator, params.validators_count });
        defer iota_managed.deinit(allocator);
        const iota_value = try encodeAndOwnSlice(allocator, state_encoder.encodeIota, .{iota_managed.ptr});
        try map.put(iota_key, .{
            .key = iota_key,
            .value = iota_value,
        });

        // Kappa (8)
        const kappa_key = state_keys.constructStateComponentKey(8);
        var kappa_managed = try getOrInitManaged(allocator, &state.kappa, .{ allocator, params.validators_count });
        defer kappa_managed.deinit(allocator);
        const kappa_value = try encodeAndOwnSlice(allocator, state_encoder.encodeKappa, .{kappa_managed.ptr});
        try map.put(kappa_key, .{
            .key = kappa_key,
            .value = kappa_value,
        });

        // Lambda (9)
        const lambda_key = state_keys.constructStateComponentKey(9);
        var lambda_managed = try getOrInitManaged(allocator, &state.lambda, .{ allocator, params.validators_count });
        defer lambda_managed.deinit(allocator);
        const lambda_value = try encodeAndOwnSlice(allocator, state_encoder.encodeLambda, .{lambda_managed.ptr});
        try map.put(lambda_key, .{
            .key = lambda_key,
            .value = lambda_value,
        });

        // Rho (10)
        const rho_key = state_keys.constructStateComponentKey(10);
        var rho_managed = try getOrInitManaged(allocator, &state.rho, .{allocator});
        defer rho_managed.deinit(allocator);

        var rho_buffer = std.ArrayList(u8).init(allocator); // TODO: reuse buffers
        try state_encoder.encodeRho(params, rho_managed.ptr, rho_buffer.writer());
        const rho_value = try rho_buffer.toOwnedSlice();
        try map.put(rho_key, .{
            .key = rho_key,
            .value = rho_value,
        });

        // Tau (11)
        const tau_key = state_keys.constructStateComponentKey(11);
        const tau_managed = if (state.tau) |tau| tau else 0; // stack managed
        const tau_value = try encodeAndOwnSlice(allocator, state_encoder.encodeTau, .{tau_managed});
        try map.put(tau_key, .{
            .key = tau_key,
            .value = tau_value,
        });

        // Chi (12)
        const chi_key = state_keys.constructStateComponentKey(12);
        var chi_managed = try getOrInitManaged(allocator, &state.chi, .{allocator});
        defer chi_managed.deinit(allocator);
        const chi_value = try encodeAndOwnSlice(allocator, state_encoder.encodeChi, .{chi_managed.ptr});
        try map.put(chi_key, .{
            .key = chi_key,
            .value = chi_value,
        });

        // Pi (13)
        const pi_key = state_keys.constructStateComponentKey(13);
        var pi_managed = try getOrInitManaged(allocator, &state.pi, .{ allocator, params.validators_count, params.core_count });
        defer pi_managed.deinit(allocator);
        const pi_value = try encodeAndOwnSlice(allocator, state_encoder.encodePi, .{pi_managed.ptr});
        try map.put(pi_key, .{
            .key = pi_key,
            .value = pi_value,
        });

        // Theta (14)
        const theta_key = state_keys.constructStateComponentKey(14);
        var theta_managed = try getOrInitManaged(allocator, &state.theta, .{allocator});
        defer theta_managed.deinit(allocator);
        const theta_value = try encodeAndOwnSlice(allocator, state_encoder.encodeTheta, .{theta_managed.ptr});
        try map.put(theta_key, .{
            .key = theta_key,
            .value = theta_value,
        });

        // Xi (15)
        const xi_key = state_keys.constructStateComponentKey(15);
        var xi_managed = try getOrInitManaged(allocator, &state.xi, .{allocator});
        defer xi_managed.deinit(allocator);
        const xi_value = try encodeAndOwnSlice(allocator, state_encoder.encodeXi, .{ params.epoch_length, allocator, &xi_managed.ptr.entries });
        try map.put(xi_key, .{
            .key = xi_key,
            .value = xi_value,
        });
    }

    // Handle delta component (service accounts) specially
    if (config.include_storage) {
        var delta_managed = try getOrInitManaged(allocator, &state.delta, .{allocator});
        defer delta_managed.deinit(allocator);
        if (delta_managed.ptr.accounts.count() > 0) {
            var service_iter = delta_managed.ptr.accounts.iterator();
            while (service_iter.next()) |service_entry| {
                const service_idx = service_entry.key_ptr.*;
                const account = service_entry.value_ptr;

                // Base account data
                const base_key = state_keys.constructServiceBaseKey(service_idx);
                var base_value = std.ArrayList(u8).init(allocator);
                try state_encoder.delta.encodeServiceAccountBase(account, base_value.writer());

                try map.put(base_key, .{
                    .key = base_key,
                    .value = try base_value.toOwnedSlice(),
                });

                // Storage entries - use the StateKey directly as it's already in final format
                var storage_iter = account.storage.iterator();
                while (storage_iter.next()) |storage_entry| {
                    const storage_key = storage_entry.key_ptr.*; // Already a properly formatted StateKey
                    try map.put(storage_key, .{
                        .key = storage_key,
                        .value = try allocator.dupe(u8, storage_entry.value_ptr.*),
                        .metadata = .{ .delta_storage = .{
                            .storage_key = storage_entry.key_ptr.*,
                        } },
                    });
                }

                if (config.include_preimages) {
                    // Preimage entries - use the StateKey directly as it's already in final format
                    var preimage_iter = account.preimages.iterator();
                    while (preimage_iter.next()) |preimage_entry| {
                        const preimage_key = preimage_entry.key_ptr.*; // Already a properly formatted StateKey
                        try map.put(preimage_key, .{
                            .key = preimage_key,
                            .value = try allocator.dupe(u8, preimage_entry.value_ptr.*),
                            .metadata = .{ .delta_preimage = .{
                                .hash = blk: {
                                    // Convert 31-byte StateKey to 32-byte hash for metadata compatibility
                                    // TODO: Update metadata structure to use StateKey directly
                                    var hash: [32]u8 = [_]u8{0} ** 32;
                                    @memcpy(hash[0..31], &preimage_entry.key_ptr.*);
                                    break :blk hash;
                                },
                                .preimage_length = @intCast(preimage_entry.value_ptr.*.len),
                            } },
                        });
                    }

                    if (config.include_preimage_timestamps) {
                        // Preimage timestamps
                        var lookup_iter = account.preimage_lookups.iterator();
                        while (lookup_iter.next()) |lookup_entry| {
                            const delta_encoder = state_encoder.delta;
                            const key: types.StateKey = lookup_entry.key_ptr.*;

                            var preimage_lookup = try std.ArrayList(u8).initCapacity(allocator, 24);
                            try delta_encoder.encodePreimageLookup(lookup_entry.value_ptr.*, preimage_lookup.writer());

                            // Use the StateKey directly as it's already properly formatted
                            try map.put(key, .{
                                .key = key,
                                .value = try preimage_lookup.toOwnedSlice(),
                                .metadata = .{
                                    .delta_preimage_lookup = .{
                                        .hash = blk: {
                                            // Extract hash from StateKey - reconstruct 32-byte hash from the structured key
                                            // Based on constructServicePreimageLookupKey: C(s, ℰ₄(l) ⌢ ℋ(h)₂...₂₉)
                                            var hash: [32]u8 = [_]u8{0} ** 32;
                                            
                                            // Length bytes are interleaved in positions 1,3,5,7 of the StateKey
                                            // Hash bytes are in positions 8-30 (corresponding to ℋ(h)₂...₂₉)
                                            // We need to reconstruct them at positions 2-29 of the 32-byte hash
                                            // key[8..31] has length 23, hash[2..30] has length 28
                                            // So we copy the available 23 bytes and leave the rest as zeros
                                            @memcpy(hash[2..25], key[8..31]);
                                            break :blk hash;
                                        },
                                        .preimage_length = blk: {
                                            // Extract length from StateKey - it's interleaved in the data portion
                                            // Based on C_variant3 with ℰ₄(l), the length is stored in data[0..4]
                                            // which gets interleaved with service_id bytes in the StateKey
                                            // Data bytes are at positions 1,3,5,7 of the StateKey (after service_id interleaving)
                                            var length_bytes: [4]u8 = undefined;
                                            length_bytes[0] = key[1]; // First data byte  
                                            length_bytes[1] = key[3]; // Second data byte
                                            length_bytes[2] = key[5]; // Third data byte
                                            length_bytes[3] = key[7]; // Fourth data byte
                                            break :blk std.mem.readInt(u32, &length_bytes, .little);
                                        },
                                    },
                                },
                            });
                        }
                    }
                }
            }
        }
    }

    return .{ .entries = map };
}

/// builds the full buildStateMerklizationDictionary
pub fn buildStateMerklizationDictionary(
    comptime params: Params,
    allocator: std.mem.Allocator,
    state: *const jamstate.JamState(params),
) !MerklizationDictionary {
    return try buildStateMerklizationDictionaryWithConfig(params, allocator, state, .{});
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

// REFACTORED: Key construction tests moved to state_keys.zig
// All key construction logic is now centralized in that module.
