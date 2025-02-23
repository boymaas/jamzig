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
    dict_entry: state_dictionary.DictEntry,
) !void {
    const span = trace.span(.reconstruct_storage_entry);
    defer span.deinit();
    span.debug("Starting storage entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&dict_entry.key), dict_entry.value.len });

    const dkey = state_dictionary.deconstructServiceIndexHashKey(dict_entry.key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    // Get or create the account
    var account = try delta.getOrCreateAccount(dkey.service_index);

    // Create owned copy of value and store with full hash
    const owned_value = try allocator.dupe(u8, dict_entry.value);
    errdefer allocator.free(owned_value);

    const storage_key = dict_entry.metadata.?.delta_storage.storage_key;
    try account.storage.put(storage_key, owned_value);
    span.debug("Successfully stored entry in account storage", .{});
}

/// Reconstructs a preimage entry for a service account by reconstructing the full hash
pub fn reconstructPreimageEntry(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    tau: ?types.TimeSlot,
    dict_entry: state_dictionary.DictEntry,
) !void {
    const span = trace.span(.reconstruct_preimage_entry);
    defer span.deinit();
    span.debug("Starting preimage entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}, Tau: {?}", .{
        std.fmt.fmtSliceHexLower(&dict_entry.key),
        dict_entry.value.len,
        tau,
    });

    const dkey = state_dictionary.deconstructServiceIndexHashKey(dict_entry.key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    // Get or create the account
    var account: *services.ServiceAccount = //
        try delta.getOrCreateAccount(dkey.service_index);

    // Create owned copy of value and store with full hash
    const owned_value = try allocator.dupe(u8, dict_entry.value);
    errdefer allocator.free(owned_value);

    // we have to decode the value to add it the account preimages, but we also do
    // not have access to the hash
    try account.preimages.put(dict_entry.metadata.?.delta_preimage.hash, owned_value);
    span.debug("Successfully stored preimage in account", .{});

    // GP0.5.0 @ 9.2.1 The state of the lookup system natu-
    // rally satisfies a number of invariants. Firstly, any preim-
    // age value must correspond to its hash.
    // TODO: leave this in??

    // if (tau == null) {
    //     log.warn("tau not set yet", .{});
    // }
    // try account.integratePreimageLookup(
    //     hash_of_value,
    //     @intCast(value.len),
    //     tau,
    // );
}

pub fn reconstructPreimageLookupEntry(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    dict_entry: state_dictionary.DictEntry,
) !void {
    const span = trace.span(.reconstruct_preimage_lookup_entry);
    defer span.deinit();
    span.debug("Starting preimage lookup entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&dict_entry.key), dict_entry.value.len });

    _ = allocator;

    // Deconstruct the dkey and the preimageLookupEntry
    const dkey = state_dictionary.deconstructServiceIndexHashKey(dict_entry.key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    // Now walk the delta to see if we have on the service a preimage which matches our hash
    var account = delta.getAccount(dkey.service_index) orelse return error.PreimageLookupEntryCannotBeReconstructedAccountMissing;

    // decode the entry
    var stream = std.io.fixedBufferStream(dict_entry.value);
    const entry = try state_decoding.delta.decodePreimageLookup(
        stream.reader(),
    );

    // add it to the account
    const metadata = dict_entry.metadata.?.delta_preimage_lookup;
    try account.preimage_lookups.put(
        services.PreimageLookupKey{ .hash = metadata.hash, .length = metadata.preimage_length },
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
