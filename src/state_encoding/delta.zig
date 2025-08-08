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

    // Calculate a_o and a_i from tracked values
    const footprint = account.getStorageFootprint();
    span.trace("Writing storage length (a_o): {d}", .{footprint.a_o});
    try writer.writeInt(u64, footprint.a_o, .little); // a_o
    //
    // Write storage_offset (optional u64) - NEW in v0.6.7

    span.trace("Writing storage_offset value: {d}", .{account.storage_offset});
    try writer.writeInt(u64, account.storage_offset, .little);

    // Write 4-byte items count (a_i)
    span.trace("Writing items count (a_i): {d}", .{footprint.a_i});
    try writer.writeInt(u32, footprint.a_i, .little);

    // se_4 encoded fields (4 bytes each)
    try writer.writeInt(types.U32, account.creation_slot, .little); // NEW: a_r
    try writer.writeInt(types.U32, account.last_accumulation_slot, .little); // NEW: a_a
    try writer.writeInt(types.U32, account.parent_service, .little); // NEW: a_p
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
