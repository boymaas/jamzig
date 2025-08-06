const std = @import("std");
const encoder = @import("../codec/encoder.zig");
const types = @import("../types.zig");
const services = @import("../services.zig");
const ServiceAccount = services.ServiceAccount;
const PreimageLookup = services.PreimageLookup;
// PreimageLookupKey removed - using types.StateKey directly

const trace = @import("../tracing.zig").scoped(.codec);

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
    span.trace("Writing storage length (a_l): {d}", .{storage_footprint.a_o});
    try writer.writeInt(u64, storage_footprint.a_o, .little); // a_l

    // Write 4-byte items count (a_i)
    span.trace("Writing items count (a_i): {d}", .{storage_footprint.a_i});
    try writer.writeInt(u32, storage_footprint.a_i, .little);
    
    // Write storage_offset (optional u64) - NEW in v0.6.7
    // Format: 1 byte presence flag + 8 bytes value if present
    if (account.storage_offset) |offset| {
        span.trace("Writing storage_offset presence flag: true", .{});
        try writer.writeByte(1); // Present
        span.trace("Writing storage_offset value: {d}", .{offset});
        try writer.writeInt(u64, offset, .little);
    } else {
        span.trace("Writing storage_offset presence flag: false", .{});
        try writer.writeByte(0); // Not present
    }
}

const state_dictionary = @import("../state_dictionary.zig");

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
    account.storage_offset = null; // Test without storage_offset first

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodeServiceAccountBase(&account, buffer.writer());

    const expected = [_]u8{1} ** 32 ++ [_]u8{
        232, 3, 0, 0, 0, 0, 0, 0, // balance: 1000
        244, 1, 0, 0, 0, 0, 0, 0, // min_gas_accumulate: 500
        250, 0, 0, 0, 0, 0, 0, 0, // min_gas_on_transfer: 250
        0,   0, 0, 0, 0, 0, 0, 0, // storage footprint bytes: 0
        0,   0, 0, 0,             // storage footprint items: 0
        0,                        // storage_offset presence flag: false
    };

    try testing.expectEqualSlices(u8, &expected, buffer.items);
    
    // Test with storage_offset present
    buffer.clearRetainingCapacity();
    account.storage_offset = 5000;
    
    try encodeServiceAccountBase(&account, buffer.writer());
    
    const expected_with_offset = [_]u8{1} ** 32 ++ [_]u8{
        232, 3, 0, 0, 0, 0, 0, 0, // balance: 1000
        244, 1, 0, 0, 0, 0, 0, 0, // min_gas_accumulate: 500
        250, 0, 0, 0, 0, 0, 0, 0, // min_gas_on_transfer: 250
        0,   0, 0, 0, 0, 0, 0, 0, // storage footprint bytes: 0
        0,   0, 0, 0,             // storage footprint items: 0
        1,                        // storage_offset presence flag: true
        136, 19, 0, 0, 0, 0, 0, 0, // storage_offset value: 5000
    };
    
    try testing.expectEqualSlices(u8, &expected_with_offset, buffer.items);
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
