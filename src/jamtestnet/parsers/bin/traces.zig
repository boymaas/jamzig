const std = @import("std");
const blob_dict = @import("../../../codec/blob_dict.zig");
const state_dictionary = @import("../../../state_dictionary.zig");

const MerklizationDictionary = state_dictionary.MerklizationDictionary;

/// Loads a state dictionary from a binary file.
/// The binary file should contain serialized key-value pairs where keys are 32-byte arrays
/// and values are variable-length byte arrays.
pub fn loadStateDictionaryBin(allocator: std.mem.Allocator, file_path: []const u8) !MerklizationDictionary {
    // Read and deserialize the binary file directly into a BlobDict
    var blob = brk: {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        break :brk try blob_dict.deserializeDict(allocator, file.reader());
    };
    defer blob.deinit();

    // Convert BlobDict to MerklizationDictionary
    var dict = MerklizationDictionary.init(allocator);
    errdefer dict.deinit();

    // Transfer ownership of entries from BlobDict to MerklizationDictionary
    var it = blob.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Note: No need to copy key/value as we're transferring ownership
        try dict.entries.put(key, value);
    }

    // Clear the blob map without freeing values since ownership was transferred
    blob.map.clearRetainingCapacity();

    return dict;
}

test "loadStateDictionaryBin" {
    const allocator = std.testing.allocator;
    var dict = try loadStateDictionaryBin(allocator, "src/stf_test/jamtestnet/traces/safrole/jam_duna/traces/genesis.bin");
    defer dict.deinit();
}
