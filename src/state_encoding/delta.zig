const std = @import("std");
const encoder = @import("../codec/encoder.zig");
const types = @import("../types.zig");
const services = @import("../services.zig");
const ServiceAccount = services.ServiceAccount;
const PreimageLookup = services.PreimageLookup;
const PreimageLookupKey = services.PreimageLookupKey;

/// Encodes base service account data: C(255, s) ↦ a_c ⌢ E_8(a_b, a_g, a_m, a_l) ⌢ E_4(a_i)
pub fn encodeServiceAccountBase(account: *const ServiceAccount, writer: anytype) !void {
    // Write code hash (a_c)
    try writer.writeAll(&account.code_hash);

    const storage_footprint = account.storageFootprint();

    // Write 8-byte values in sequence (a_b, a_g, a_m, a_l)
    try writer.writeInt(u64, account.balance, .little); // a_b
    try writer.writeInt(u64, account.min_gas_accumulate, .little); // a_g
    try writer.writeInt(u64, account.min_gas_on_transfer, .little); // a_m
    try writer.writeInt(u64, storage_footprint.a_l, .little); // a_l

    // Write 4-byte items count (a_i)
    try writer.writeInt(u32, storage_footprint.a_i, .little);
}

/// Encodes storage entries: C(s, h) ↦ v
pub fn encodeStorageEntry(storage_entry: []const u8, writer: anytype) !void {
    // Write value (v)
    try writer.writeAll(storage_entry);
}

/// Encodes preimage lookups: C(s, h) ↦ p
pub fn encodePreimage(pre_image: []const u8, writer: anytype) !void {
    // Write value (p)
    try writer.writeAll(pre_image);
}

/// Encodes preimage timestamps: E_4(l) ⌢ (¬h_4...)
pub fn encodePreimageKey(key: PreimageLookupKey, writer: anytype) !void {
    // Write length (l) as 4 bytes
    try writer.writeInt(u32, key.length, .little);

    // Create modified hash with inverted upper bits
    var modified_hash: [28]u8 = key.hash[4..].*;
    for (&modified_hash) |*byte| {
        byte.* = ~byte.*;
    }
    try writer.writeAll(&modified_hash);
}

/// Encodes preimage lookup:  E(↕[E_4(x) | x <− t])
pub fn encodePreimageLookup(lookup: PreimageLookup, writer: anytype) !void {
    // Count non-null timestamps
    var timestamp_count: usize = 0;
    for (lookup.status) |maybe_timestamp| brk: {
        if (maybe_timestamp != null) timestamp_count += 1 else break :brk;
    }

    // Write timestamps with length prefix
    try writer.writeAll(encoder.encodeInteger(timestamp_count).as_slice());
    for (0..timestamp_count) |i| {
        try writer.writeInt(u32, lookup.status[i].?, .little);
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

test "encodePreimage" {
    const pre_image = [_]u8{ 1, 2, 3, 4, 5 };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodePreimage(&pre_image, buffer.writer());

    try testing.expectEqualSlices(u8, &pre_image, buffer.items);
}

test "encodePreimageKey" {
    const key = PreimageLookupKey{
        .length = 5,
        .hash = [_]u8{0xFF} ** 32,
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodePreimageKey(key, buffer.writer());

    const expected = [_]u8{ 5, 0, 0, 0 } ++ [_]u8{0x00} ** 28;

    try testing.expectEqualSlices(u8, &expected, buffer.items);
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
