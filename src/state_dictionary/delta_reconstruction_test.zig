const std = @import("std");
const testing = std.testing;
const state = @import("../state.zig");
const types = @import("../types.zig");
const state_dictionary = @import("../state_dictionary.zig");
const MerklizationDictionary = @import("../state_dictionary.zig").MerklizationDictionary;
const delta_reconstruction = @import("delta_reconstruction.zig");
const Params = @import("../jam_params.zig").Params;
const reconstruct = @import("reconstruct.zig");
const state_keys = @import("../state_keys.zig");

const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);

const TINY = @import("../jam_params.zig").TINY_PARAMS;

test "reconstruct delta base account" {
    // Setup
    const allocator = testing.allocator;

    var delta = state.Delta.init(allocator);
    defer delta.deinit();

    const service_id: u32 = 42;

    // Create a base account key using new service_keys module
    const base_key = state_keys.constructServiceBaseKey(service_id);

    // Create sample account data (114 bytes for new format)
    // 32 bytes code_hash + 8 balance + 8 min_gas_accumulate + 8 min_gas_on_transfer + 
    // 8 storage_length + 8 storage_offset + 4 items_count + 4 creation_slot + 
    // 4 last_accumulation_slot + 4 previous_total_gas + 4 previous_item_gas + 
    // 8 total_gas_capacity + 4 threshold_percent + 4 min_accum_gas + 
    // 4 min_on_transfer_gas + 2 preimage_lookups_count = 114 bytes
    const base_value = [_]u8{0} ** 114; // Sample account data matching new format

    // Test reconstruction
    try delta_reconstruction.reconstructServiceAccountBase(allocator, &delta, base_key, &base_value);

    // Verify
    try testing.expect(delta.accounts.contains(service_id));
}
