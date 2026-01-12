const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const services = @import("../services.zig");
const DecodingError = @import("../state_decoding.zig").DecodingError;

pub fn decodeServiceAccountBase(
    _: std.mem.Allocator,
    delta: *state.Delta,
    service_id: types.ServiceId,
    reader: anytype,
) !void {
    const version = try reader.readByte();
    if (version != 0) {
        return error.UnexpectedVersion;
    }

    const code_hash = try readHash(reader);

    const balance = try reader.readInt(types.U64, .little);
    const min_item_gas = try reader.readInt(types.Gas, .little);
    const min_memo_gas = try reader.readInt(types.Gas, .little);
    const bytes = try reader.readInt(types.U64, .little);

    const storage_offset = try reader.readInt(types.U64, .little);

    const items = try reader.readInt(types.U32, .little);
    const creation_slot = try reader.readInt(types.U32, .little);
    const last_accumulation_slot = try reader.readInt(types.U32, .little);
    const parent_service = try reader.readInt(types.U32, .little);

    var account = try delta.getOrCreateAccount(service_id);
    account.version = 0;
    account.code_hash = code_hash;
    account.balance = balance;
    account.min_gas_accumulate = min_item_gas;
    account.min_gas_on_transfer = min_memo_gas;
    account.storage_offset = storage_offset;
    account.creation_slot = creation_slot;
    account.last_accumulation_slot = last_accumulation_slot;
    account.parent_service = parent_service;

    account.footprint_items = items;
    account.footprint_bytes = bytes;
}

pub fn decodePreimageLookup(reader: anytype) !services.PreimageLookup {
    const codec = @import("../codec.zig");
    const timestamp_count = try codec.readInteger(reader);
    if (timestamp_count > 3) return error.InvalidData;

    var lookup = services.PreimageLookup{
        .status = .{ null, null, null },
    };

    for (0..timestamp_count) |i| {
        const timestamp = try reader.readInt(u32, .little);
        lookup.status[i] = timestamp;
    }

    return lookup;
}

fn readHash(reader: anytype) !types.OpaqueHash {
    var hash: types.OpaqueHash = undefined;
    const bytes_read = try reader.readAll(&hash);
    if (bytes_read != hash.len) {
        return DecodingError.EndOfStream;
    }
    return hash;
}
