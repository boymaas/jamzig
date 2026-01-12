const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const state_decoding = @import("../state_decoding.zig");
const state_dictionary = @import("../state_dictionary.zig");
const services = @import("../services.zig");
const state_recovery = @import("../state_recovery.zig");

const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);
const trace = @import("tracing").scoped(.codec);

const log = std.log.scoped(.state_dictionary);

pub fn reconstructServiceAccountBase(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    key: types.StateKey,
    value: []const u8,
) !void {
    const span = trace.span(@src(), .reconstruct_service_account_base);
    defer span.deinit();
    span.debug("Starting service account base reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&key), value.len });

    var stream = std.io.fixedBufferStream(value);
    const reader = stream.reader();

    const dkey = state_recovery.deconstructByteServiceIndexKey(key);
    std.debug.assert(dkey.byte == 255);
    span.debug("Deconstructed key - service index: {d}, byte: {d}", .{ dkey.service_index, dkey.byte });

    try state_decoding.delta.decodeServiceAccountBase(allocator, delta, dkey.service_index, reader);
}

pub fn reconstructStorageData(
    allocator: std.mem.Allocator,
    delta: *state.Delta,
    dict_entry: state_dictionary.DictEntry,
) !void {
    const span = trace.span(@src(), .reconstruct_storage_data);
    defer span.deinit();
    span.debug("Starting storage entry reconstruction", .{});
    span.trace("Key: {any}, Value length: {d}", .{ std.fmt.fmtSliceHexLower(&dict_entry.key), dict_entry.value.len });

    const dkey = state_recovery.deconstructServiceIndexHashKey(dict_entry.key);
    span.debug("Deconstructed service index: {d}", .{dkey.service_index});

    var account = try delta.getOrCreateAccount(dkey.service_index);

    const owned_value = try allocator.dupe(u8, dict_entry.value);
    errdefer allocator.free(owned_value);

    const storage_key = dict_entry.key;
    try account.data.put(storage_key, owned_value);
}
