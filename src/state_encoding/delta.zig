const std = @import("std");
const encoder = @import("../codec/encoder.zig");
const types = @import("../types.zig");
const services = @import("../services.zig");
const ServiceAccount = services.ServiceAccount;
const PreimageLookup = services.PreimageLookup;
const PreimageLookupKey = services.PreimageLookupKey;

const trace = @import("../tracing.zig").scoped(.delta_encoding);

/// Encodes base service account data: C(255, s) ↦ a_c ⌢ E_8(a_b, a_g, a_m, a_l) ⌢ E_4(a_i)
pub fn encodeServiceAccountBase(account: *const ServiceAccount, writer: anytype) !void {
    const span = trace.span(.encode_service_account_base);
    defer span.deinit();
    span.debug("Starting service account base encoding", .{});

    // Write code hash (a_c)
    span.trace("Writing code hash: {s}", .{std.fmt.fmtSliceHexLower(&account.code_hash)});
    try writer.writeAll(&account.code_hash);

    // Write 8-byte values in sequence (a_b, a_g, a_m, a_l)
    span.trace("Writing balance: {d}", .{account.balance});
    try writer.writeInt(u64, account.balance, .little); // a_b
    span.trace("Writing min gas accumulate: {d}", .{account.min_gas_accumulate});
    try writer.writeInt(u64, account.min_gas_accumulate, .little); // a_g
    span.trace("Writing min gas on transfer: {d}", .{account.min_gas_on_transfer});
    try writer.writeInt(u64, account.min_gas_on_transfer, .little); // a_m

    const storage_footprint = account.storageFootprint();
    span.trace("Writing storage length (a_l): {d}", .{storage_footprint.a_l});
    try writer.writeInt(u64, storage_footprint.a_l, .little); // a_l

    // Write 4-byte items count (a_i)
    span.trace("Writing items count (a_i): {d}", .{storage_footprint.a_i});
    try writer.writeInt(u32, storage_footprint.a_i, .little);
}

const state_dictionary = @import("../state_dictionary.zig");

/// Encodes storage entries: C(s, h) ↦ v
pub fn encodeStorageEntry(storage_entry: []const u8, writer: anytype) !void {
    const span = trace.span(.encode_storage_entry);
    defer span.deinit();
    span.debug("Starting storage entry encoding", .{});
    span.trace("Storage entry length: {d}", .{storage_entry.len});
    span.trace("Storage entry data: {s}", .{std.fmt.fmtSliceHexLower(storage_entry)});
    // Write value (v)
    try writer.writeAll(storage_entry);
}

/// Encodes storage key using buildStorageKey helper
pub fn encodeStorageEntryKey(key: [32]u8, writer: anytype) !void {
    const span = trace.span(.encode_storage_entry_key);
    defer span.deinit();
    span.debug("Starting storage entry key encoding", .{});
    span.trace("Input key: {s}", .{std.fmt.fmtSliceHexLower(&key)});

    const storage_key = state_dictionary.buildStorageKey(key);
    try writer.writeAll(&storage_key);
}

/// Encodes preimage key using buildPreimageKey helper
pub fn encodePreimageKey(key: [32]u8, writer: anytype) !void {
    const span = trace.span(.encode_preimage_key);
    defer span.deinit();
    span.debug("Starting preimage key encoding", .{});
    span.trace("Input key: {s}", .{std.fmt.fmtSliceHexLower(&key)});

    const preimage_key = state_dictionary.buildPreimageKey(key);
    try writer.writeAll(&preimage_key);
}

/// Encodes preimage lookups: C(s, h) ↦ p
pub fn encodePreimage(pre_image: []const u8, writer: anytype) !void {
    const span = trace.span(.encode_preimage);
    defer span.deinit();
    span.debug("Starting preimage encoding", .{});
    span.trace("Preimage length: {d}", .{pre_image.len});
    span.trace("Preimage data: {s}", .{std.fmt.fmtSliceHexLower(pre_image)});

    // Write value (p)
    try writer.writeAll(pre_image);
}

/// Encodes preimage timestamps: E_4(l) ⌢ (¬h_4...)
pub fn encodePreimageLookupKey(key: PreimageLookupKey, writer: anytype) !void {
    const span = trace.span(.encode_preimage_lookup_key);
    defer span.deinit();
    span.debug("Starting preimage lookup key encoding", .{});
    span.trace("Key hash: {s}, length: {d}", .{ std.fmt.fmtSliceHexLower(&key.hash), key.length });

    const preimage_lookup_key = @import("../state_dictionary.zig").buildPreimageLookupKey(key);
    try writer.writeAll(&preimage_lookup_key);
}

/// Encodes preimage lookup:  E(↕[E_4(x) | x <− t])
pub fn encodePreimageLookup(lookup: PreimageLookup, writer: anytype) !void {
    const span = trace.span(.encode_preimage_lookup);
    defer span.deinit();
    span.debug("Starting preimage lookup encoding", .{});

    // Count non-null timestamps
    var timestamp_count: usize = 0;
    for (lookup.status) |maybe_timestamp| brk: {
        if (maybe_timestamp != null) timestamp_count += 1 else break :brk;
    }
    span.trace("Non-null timestamp count: {d}", .{timestamp_count});

    // Write timestamps with length prefix
    span.trace("Writing timestamp count prefix", .{});
    try writer.writeAll(encoder.encodeInteger(timestamp_count).as_slice());
    for (0..timestamp_count) |i| {
        const timestamp = lookup.status[i].?;
        span.trace("Writing timestamp {d}: {d}", .{ i, timestamp });
        try writer.writeInt(u32, timestamp, .little);
    }
}

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_ ___
// | | | | '_ \| | __|| |/ _ \/ __| __/ __|
// | |_| | | | | | |_ | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__||_|\___||___/\__|___/

const testing = std.testing;

test "encodeServiceAccountBase" {
    var account = ServiceAccount.init(testing.allocator);
    account.code_hash = [_]u8{1} ** 32;
    account.balance = 1000;
    account.min_gas_accumulate = 500;
    account.min_gas_on_transfer = 250;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodeServiceAccountBase(&account, buffer.writer());

    const expected = [_]u8{1} ** 32 ++ [_]u8{
        232, 3, 0, 0, 0, 0, 0, 0,
        244, 1, 0, 0, 0, 0, 0, 0,
        250, 0, 0, 0, 0, 0, 0, 0,
        0,   0, 0, 0, 0, 0, 0, 0,
        0,   0, 0, 0,
    };

    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "encodeStorageEntry" {
    const storage_entry = [_]u8{ 10, 20, 30, 40, 50 };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodeStorageEntry(&storage_entry, buffer.writer());

    try testing.expectEqualSlices(u8, &storage_entry, buffer.items);
}

test "encodePreimageKey" {
    const key = [_]u8{0x44} ** 32;

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodePreimageKey(key, buffer.writer());

    const expected = [_]u8{ 0xFE, 0xFF, 0xFF, 0xFF } ++ [_]u8{0x44} ** 28;

    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "encodePreimage" {
    const pre_image = [_]u8{ 1, 2, 3, 4, 5 };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodePreimage(&pre_image, buffer.writer());

    try testing.expectEqualSlices(u8, &pre_image, buffer.items);
}

test "encodePreimageLookup" {
    const lookup = PreimageLookup{
        .status = [_]?u32{ 1, 2, null },
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodePreimageLookup(lookup, buffer.writer());

    const expected = [_]u8{2} ++ [_]u8{
        1, 0, 0, 0, //
        2, 0, 0, 0, //
    };

    try testing.expectEqualSlices(u8, &expected, buffer.items);
}
