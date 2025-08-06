const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const services = @import("../services.zig");
const DecodingError = @import("../state_decoding.zig").DecodingError;

/// Decodes base service account data and adds/updates the account in delta
/// Base account data includes service info like code hash, balance, gas limits etc
pub fn decodeServiceAccountBase(
    _: std.mem.Allocator, // TODO: remove?
    delta: *state.Delta,
    service_id: types.ServiceId,
    reader: anytype,
) !void {
    // Read basic service info fields from the encoded data
    const code_hash = try readHash(reader);
    const balance = try reader.readInt(types.U64, .little);
    const min_item_gas = try reader.readInt(types.Gas, .little);
    const min_memo_gas = try reader.readInt(types.Gas, .little);
    const bytes = try reader.readInt(types.U64, .little);
    const items = try reader.readInt(types.U32, .little);

    // Construct account
    var account = try delta.getOrCreateAccount(service_id);
    account.code_hash = code_hash;
    account.balance = balance;
    account.min_gas_accumulate = min_item_gas;
    account.min_gas_on_transfer = min_memo_gas;

    // FIXME: these are calculatd from the storage footprint
    // need to integrate these
    // account.bytes = bytes;
    // account.items = items;
    _ = bytes;
    _ = items;
    
    // Read storage_offset (optional u64) - NEW in v0.6.7
    // Format: 1 byte presence flag + 8 bytes value if present
    const has_storage_offset = try reader.readByte();
    if (has_storage_offset != 0) {
        account.storage_offset = try reader.readInt(u64, .little);
    } else {
        account.storage_offset = null;
    }
}

/// Decodes a preimage lookup from the encoded format: E(↕[E_4(x) | x <− t])
/// The encoding consists of a length prefix followed by timestamps
pub fn decodePreimageLookup(reader: anytype) !services.PreimageLookup {

    // Read timestamp count
    const codec = @import("../codec.zig");
    const timestamp_count = try codec.readInteger(reader);
    if (timestamp_count > 3) return error.InvalidData;

    // Initialize lookup with null status
    var lookup = services.PreimageLookup{
        .status = .{ null, null, null },
    };

    // Read timestamps
    for (0..timestamp_count) |i| {
        const timestamp = try reader.readInt(u32, .little);
        lookup.status[i] = timestamp;
    }

    return lookup;
}

/// Helper function to read a 32-byte hash
fn readHash(reader: anytype) !types.OpaqueHash {
    var hash: types.OpaqueHash = undefined;
    const bytes_read = try reader.readAll(&hash);
    if (bytes_read != hash.len) {
        return DecodingError.EndOfStream;
    }
    return hash;
}

test "decodeServiceAccountBase" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var delta = state.Delta.init(allocator);
    defer delta.deinit();

    // Create test data
    const service_id: types.ServiceId = 42;
    const code_hash = [_]u8{1} ** 32;
    const balance: types.U64 = 1000;
    const min_item_gas: types.Gas = 100;
    const min_memo_gas: types.Gas = 50;
    const bytes: types.U64 = 500;
    const items: types.U32 = 10;

    // Test 1: Without storage_offset
    {
        // Create a buffer with encoded data (no storage_offset)
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll(&code_hash);
        try writer.writeInt(types.U64, balance, .little);
        try writer.writeInt(types.Gas, min_item_gas, .little);
        try writer.writeInt(types.Gas, min_memo_gas, .little);
        try writer.writeInt(types.U64, bytes, .little);
        try writer.writeInt(types.U32, items, .little);
        try writer.writeByte(0); // storage_offset not present

        // Test decoding
        var stream = std.io.fixedBufferStream(buffer.items);
        try decodeServiceAccountBase(allocator, &delta, service_id, stream.reader());

        // Verify results
        try testing.expect(delta.accounts.contains(service_id));
        const account = delta.accounts.get(service_id).?;

        try testing.expectEqualSlices(u8, &code_hash, &account.code_hash);
        try testing.expectEqual(balance, account.balance);
        try testing.expectEqual(min_item_gas, account.min_gas_accumulate);
        try testing.expectEqual(min_memo_gas, account.min_gas_on_transfer);
        try testing.expectEqual(@as(?u64, null), account.storage_offset);
    }
    
    // Test 2: With storage_offset
    {
        const service_id_2: types.ServiceId = 43;
        const storage_offset_value: u64 = 5000;
        
        // Create a buffer with encoded data (with storage_offset)
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll(&code_hash);
        try writer.writeInt(types.U64, balance, .little);
        try writer.writeInt(types.Gas, min_item_gas, .little);
        try writer.writeInt(types.Gas, min_memo_gas, .little);
        try writer.writeInt(types.U64, bytes, .little);
        try writer.writeInt(types.U32, items, .little);
        try writer.writeByte(1); // storage_offset present
        try writer.writeInt(u64, storage_offset_value, .little);

        // Test decoding
        var stream = std.io.fixedBufferStream(buffer.items);
        try decodeServiceAccountBase(allocator, &delta, service_id_2, stream.reader());

        // Verify results
        try testing.expect(delta.accounts.contains(service_id_2));
        const account = delta.accounts.get(service_id_2).?;

        try testing.expectEqualSlices(u8, &code_hash, &account.code_hash);
        try testing.expectEqual(balance, account.balance);
        try testing.expectEqual(min_item_gas, account.min_gas_accumulate);
        try testing.expectEqual(min_memo_gas, account.min_gas_on_transfer);
        try testing.expectEqual(@as(?u64, storage_offset_value), account.storage_offset);
    }
    // bytes and items are not currently used
    // try testing.expectEqual(bytes, account.bytes);
    // try testing.expectEqual(items, account.items);
}
