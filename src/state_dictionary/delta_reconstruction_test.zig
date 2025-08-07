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

    // Create sample account data
    const base_value = [_]u8{1} ** 68 ++ [_]u8{0} ** 1; // Sample account data

    // Test reconstruction
    try delta_reconstruction.reconstructServiceAccountBase(allocator, &delta, base_key, &base_value);

    // Verify
    try testing.expect(delta.accounts.contains(service_id));
}
