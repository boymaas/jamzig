const std = @import("std");
const blob_dict = @import("../../codec/blob_dict.zig");
const state_dictionary = @import("../../state_dictionary.zig");
const types = @import("../../types.zig");

const MerklizationDictionary = state_dictionary.MerklizationDictionary;

/// Loads a state dictionary from a binary file.
/// The binary file should contain serialized key-value pairs where keys are 32-byte arrays
/// and values are variable-length byte arrays.
pub fn blobDictToMerklizationDictionary(allocator: std.mem.Allocator, blob: blob_dict.BlobDict) !MerklizationDictionary {
    // Convert BlobDict to MerklizationDictionary
    var dict = MerklizationDictionary.init(allocator);
    errdefer dict.deinit();

    // Transfer ownership of entries from BlobDict to MerklizationDictionary
    var it = blob.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = try allocator.dupe(u8, entry.value_ptr.*);

        // Note: No need to copy key/value as we're transferring ownership
        try dict.entries.put(key, value);
    }

    return dict;
}

/// Parse a hex string (with or without "0x" prefix) into a Hash
pub fn parseHash(hex_str: []const u8) ![32]u8 {
    var hash: [32]u8 = undefined;
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    _ = try std.fmt.hexToBytes(&hash, clean_hex);
    return hash;
}

/// Parse a hex string into a StateRoot
pub fn parseStateRoot(allocator: std.mem.Allocator, hex_str: []const u8) !types.StateRoot {
    _ = allocator; // Not needed for fixed-size array
    return parseHash(hex_str);
}

/// Convert hex string to bytes
pub fn hexToBytes(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(bytes, clean_hex);
    return bytes;
}
