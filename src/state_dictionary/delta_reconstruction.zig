const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const state_decoding = @import("../state_decoding.zig");
const state_dictionary = @import("../state_dictionary.zig");
const services = @import("../services.zig");

const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);
const trace = @import("../tracing.zig").scoped(.codec);

const log = std.log.scoped(.state_dictionary_reconstruct);

/// Reconstructs base service account data from key type 255
pub fn reconstructServiceAccountBase(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    key: [32]u8,
    value: []const u8,
) !void {
    const span = trace.span(.reconstruct_service_account_base);
    defer span.deinit();
    span.debug("Starting service account base reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&key), value.len });

    var stream = std.io.fixedBufferStream(value);
    const reader = stream.reader();

    const dkey = state_dictionary.deconstructByteServiceIndexKey(key);
    std.debug.assert(dkey.byte == 255);
    span.debug("Deconstructed key - service index: {d}, byte: {d}", .{ dkey.service_index, dkey.byte });

    // Decode base account data using existing decoder
    try state_decoding.delta.decodeServiceAccountBase(allocator, delta, dkey.service_index, reader);
}

/// Reconstructs a storage entry for a service account by reconstructing the full hash
pub fn reconstructStorageEntry(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    key: [32]u8,
    value: []const u8,
) !void {
    const span = trace.span(.reconstruct_storage_entry);
    defer span.deinit();
    span.debug("Starting storage entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&key), value.len });

    const dkey = state_dictionary.deconstructServiceIndexHashKey(key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    // NOTE: its too bad we cannot reconstruct the full key, we essentially only have 24 of keyspace
    //       if services use keys higher than this we cannot deconstruct. Since this is used
    //       in tests, lets approve of keys which are small
    const partial_storage_key = state_dictionary.deconstructStorageKey(dkey.hash.hash) orelse return error.InvalidKey;
    span.trace("Deconstructed storage key: {x}", .{partial_storage_key});

    // Check if the storage key has enough leading zeros to be considered valid
    // We'll consider it valid if at least the first 3 bytes are zero
    const required_leading_zeros = 3;
    var zero_count: usize = 0;

    for (partial_storage_key) |byte| {
        if (byte == 0) {
            zero_count += 1;
        } else {
            break;
        }
    }

    if (zero_count < required_leading_zeros) {
        span.err("Storage key does not have enough leading zeros: found {d}, required {d} cannot identify this is a test restore", .{
            zero_count, required_leading_zeros,
        });
        return error.InvalidStorageKeyReconstruction;
    }

    // Get or create the account
    var account = try delta.getOrCreateAccount(dkey.service_index);

    // Create owned copy of value and store with full hash
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);

    const storage_key = [_]u8{0} ** 8 ++ partial_storage_key;
    try account.storage.put(storage_key, owned_value);
    span.debug("Successfully stored entry in account storage", .{});
}

/// Reconstructs a preimage entry for a service account by reconstructing the full hash
pub fn reconstructPreimageEntry(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    tau: ?types.TimeSlot,
    key: [32]u8,
    value: []const u8,
) !void {
    const span = trace.span(.reconstruct_preimage_entry);
    defer span.deinit();
    span.debug("Starting preimage entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}, Tau: {?}", .{
        std.fmt.fmtSliceHexLower(&key),
        value.len,
        tau,
    });

    const dkey = state_dictionary.deconstructServiceIndexHashKey(key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    const dhash = state_dictionary.deconstructPreimageKey(dkey.hash.hash) orelse return error.InvalidKey;
    span.trace("Deconstructed hash: {any}", .{std.fmt.fmtSliceHexLower(&dkey.hash.hash)});

    // NOTE: this dhash contains a lossy hash of the preimage hash which we could use
    // to rebuild the state. But it's messy.

    // Get or create the account
    var account: *services.ServiceAccount = //
        try delta.getOrCreateAccount(dkey.service_index);

    // Create owned copy of value and store with full hash
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);

    // Calculate hash of the value
    var hash_of_value: [32]u8 = undefined;
    Blake2b256.hash(value, &hash_of_value, .{});
    span.trace("Calculated hash of value: {any}", .{std.fmt.fmtSliceHexLower(&hash_of_value)});

    if (!dhash.matches(&hash_of_value)) {
        span.err("Hash mismatch - expected: {any}, got: {any}", .{
            std.fmt.fmtSliceHexLower(&dkey.hash.hash),
            std.fmt.fmtSliceHexLower(&hash_of_value),
        });
        return error.DeconstructedPreimageEntryKeyHashMismatch;
    }

    // we have to decode the value to add it the account preimages, but we also do
    // not have access to the hash
    try account.preimages.put(hash_of_value, owned_value);
    span.debug("Successfully stored preimage in account", .{});

    // GP0.5.0 @ 9.2.1 The state of the lookup system natu-
    // rally satisfies a number of invariants. Firstly, any preim-
    // age value must correspond to its hash.

    if (tau == null) {
        log.warn("tau not set yet", .{});
    }
    try account.integratePreimageLookup(
        hash_of_value,
        @intCast(value.len),
        tau,
    );
}

pub fn reconstructPreimageLookupEntry(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    key: [32]u8,
    value: []const u8,
) !void {
    const span = trace.span(.reconstruct_preimage_lookup_entry);
    defer span.deinit();
    span.debug("Starting preimage lookup entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&key), value.len });

    _ = allocator;

    // Deconstruct the dkey and the preimageLookupEntry
    const dkey = state_dictionary.deconstructServiceIndexHashKey(key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    const dhash = state_dictionary.deconstructPreimageLookupKey(dkey.hash.hash);
    span.trace("Deconstructed hash: {any}, length: {d}", .{
        dhash.lossy_hash_of_hash,
        dhash.length,
    });

    // Now walk the delta to see if we have on the service a preimage which matches our hash
    var account = delta.getAccount(dkey.service_index) orelse return error.PreimageLookupEntryCannotBeReconstructedAccountMissing;
    var key_iter = account.preimages.keyIterator();

    if (account.preimages.count() == 0) {
        return error.PreimageLookupEntryCannotBeReconstructedNoPreimagesInAccount;
    }

    var restored_hash: ?types.OpaqueHash = null;
    while (key_iter.next()) |preimage_key| {
        // We need to compare against the hash of hash
        var hash_of_preimage_key: types.OpaqueHash = undefined;
        Blake2b256.hash(preimage_key, &hash_of_preimage_key, .{});

        span.trace("Tyring match of preimagekey: {x} against {}", .{ std.fmt.fmtSliceHexLower(&hash_of_preimage_key), dhash.lossy_hash_of_hash });
        if (dhash.lossy_hash_of_hash.matches(&hash_of_preimage_key)) {
            restored_hash = preimage_key.*;
            span.debug("Found matching hash in preimages", .{});
            span.trace("Restored hash: {any}", .{std.fmt.fmtSliceHexLower(preimage_key)});
            break;
        }
    }

    // TODO: check if the length is correct against the preimage

    if (restored_hash == null) {
        span.err("Could not find matching hash in preimages", .{});

        return error.PreimageLookupEntryCannotBeReconstructedMissingHashInPreImages;
    }

    // decode the entry
    var stream = std.io.fixedBufferStream(value);
    const entry = try state_decoding.delta.decodePreimageLookup(
        stream.reader(),
    );

    // add it to the account
    try account.preimage_lookups.put(
        services.PreimageLookupKey{ .hash = restored_hash.?, .length = dhash.length },
        entry,
    );
}

test "reconstructStorageEntry with hash reconstruction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var delta = state.Delta.init(allocator);
    defer delta.deinit();

    const service_id: u32 = 42;
    const value = "test value";

    // Calculate hash of value to get lossy hash
    var full_hash: [32]u8 = undefined;
    Blake2b256.hash(value, &full_hash, .{});

    // Build the key
    const key = state_dictionary.constructServiceIndexHashKey(
        service_id,
        state_dictionary.buildStorageKey(full_hash),
    );

    // Test reconstruction
    try reconstructStorageEntry(allocator, &delta, key, value);

    // Verify storage entry
    const account = delta.accounts.get(service_id) orelse return error.AccountNotFound;
    const stored_value = account.storage.get(full_hash) orelse return error.ValueNotFound;
    try testing.expectEqualStrings(value, stored_value);
}

test "reconstructPreimageEntry with hash reconstruction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var delta = state.Delta.init(allocator);
    defer delta.deinit();

    const service_id: u32 = 42;
    const value = "test preimage value";

    // Calculate hash of value to get lossy hash
    var full_hash: [32]u8 = undefined;
    Blake2b256.hash(value, &full_hash, .{});

    const key = state_dictionary.constructServiceIndexHashKey(
        service_id,
        state_dictionary.buildPreimageKey(full_hash),
    );

    // Test reconstruction
    try reconstructPreimageEntry(allocator, &delta, null, key, value);

    // Verify preimage entry
    const account = delta.accounts.get(service_id) orelse return error.AccountNotFound;
    const stored_value = account.preimages.get(full_hash) orelse return error.ValueNotFound;
    try testing.expectEqualStrings(value, stored_value);
}
