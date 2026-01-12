const std = @import("std");
const encoder = @import("../codec/encoder.zig");
const types = @import("../types.zig");
const services = @import("../services.zig");
const ServiceAccount = services.ServiceAccount;
const PreimageLookup = services.PreimageLookup;
const Params = @import("../jam_params.zig").Params;

const trace = @import("tracing").scoped(.codec);

pub fn encodeServiceAccountBase(params: Params, account: *const ServiceAccount, writer: anytype) !void {
    const span = trace.span(@src(), .encode_service_account_base);
    defer span.deinit();
    span.debug("Starting service account base encoding", .{});

    span.trace("Writing merklization version byte: 0", .{});
    try writer.writeByte(0);

    span.trace("Writing code hash: {s}", .{std.fmt.fmtSliceHexLower(&account.code_hash)});
    try writer.writeAll(&account.code_hash);

    span.trace("Writing balance: {d}", .{account.balance});
    try writer.writeInt(u64, account.balance, .little);
    span.trace("Writing min gas accumulate: {d}", .{account.min_gas_accumulate});
    try writer.writeInt(u64, account.min_gas_accumulate, .little);
    span.trace("Writing min gas on transfer: {d}", .{account.min_gas_on_transfer});
    try writer.writeInt(u64, account.min_gas_on_transfer, .little);

    const footprint = account.getStorageFootprint(params);
    span.trace("Writing storage length (a_o): {d}", .{footprint.a_o});
    try writer.writeInt(u64, footprint.a_o, .little);

    span.trace("Writing storage_offset value: {d}", .{account.storage_offset});
    try writer.writeInt(u64, account.storage_offset, .little);

    span.trace("Writing items count (a_i): {d}", .{footprint.a_i});
    try writer.writeInt(u32, footprint.a_i, .little);
    try writer.writeInt(types.U32, account.creation_slot, .little);
    try writer.writeInt(types.U32, account.last_accumulation_slot, .little);
    try writer.writeInt(types.U32, account.parent_service, .little);
}

const state_dictionary = @import("../state_dictionary.zig");

pub fn encodePreimageLookup(lookup: PreimageLookup, writer: anytype) !void {
    const span = trace.span(@src(), .encode_preimage_lookup);
    defer span.deinit();
    span.debug("Starting preimage lookup encoding", .{});

    var timestamp_count: usize = 0;
    for (lookup.status) |maybe_timestamp| brk: {
        if (maybe_timestamp != null) timestamp_count += 1 else break :brk;
    }
    span.trace("Non-null timestamp count: {d}", .{timestamp_count});

    span.trace("Writing timestamp count prefix", .{});
    try writer.writeAll(encoder.encodeInteger(timestamp_count).as_slice());
    for (0..timestamp_count) |i| {
        const timestamp = lookup.status[i].?;
        span.trace("Writing timestamp {d}: {d}", .{ i, timestamp });
        try writer.writeInt(u32, timestamp, .little);
    }
}

const testing = std.testing;
const jam_params = @import("../jam_params.zig");
const state = @import("../state.zig");

test "ServiceAccount base encoding roundtrip with version byte" {
    const allocator = testing.allocator;
    const params = jam_params.TINY_PARAMS;
    const state_decoding = @import("../state_decoding.zig");

    var original = ServiceAccount.init(allocator);
    defer original.deinit();

    original.code_hash = [_]u8{0xAB} ** 32;
    original.balance = 1000;
    original.min_gas_accumulate = 100;
    original.min_gas_on_transfer = 200;
    original.storage_offset = 500;
    original.creation_slot = 10;
    original.last_accumulation_slot = 5;
    original.parent_service = 0;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encodeServiceAccountBase(params, &original, buffer.writer());

    try testing.expectEqual(@as(usize, 89), buffer.items.len);
    try testing.expectEqual(@as(u8, 0), buffer.items[0]);

    var fbs = std.io.fixedBufferStream(buffer.items);
    var delta = state.Delta.init(allocator);
    defer delta.deinit();

    const service_id: u32 = 1;
    try state_decoding.delta.decodeServiceAccountBase(allocator, &delta, service_id, fbs.reader());

    const decoded = delta.getAccount(service_id).?;
    try testing.expectEqualSlices(u8, &original.code_hash, &decoded.code_hash);
    try testing.expectEqual(original.balance, decoded.balance);
    try testing.expectEqual(original.min_gas_accumulate, decoded.min_gas_accumulate);
    try testing.expectEqual(original.min_gas_on_transfer, decoded.min_gas_on_transfer);
    try testing.expectEqual(original.storage_offset, decoded.storage_offset);
    try testing.expectEqual(original.creation_slot, decoded.creation_slot);
    try testing.expectEqual(original.last_accumulation_slot, decoded.last_accumulation_slot);
    try testing.expectEqual(original.parent_service, decoded.parent_service);
    const footprint = original.getStorageFootprint(params);
    try testing.expectEqual(footprint.a_i, decoded.footprint_items);
    try testing.expectEqual(footprint.a_o, decoded.footprint_bytes);
}
