const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ordered_files = @import("../../../tests/ordered_files.zig");
const getOrderedFiles = ordered_files.getOrderedFiles;
const hex_bytes = @import("../../../tests/vectors/libs/types/hex_bytes.zig");

const state_dictionary = @import("../../../state_dictionary.zig");
const MerklizationDictionary = state_dictionary.MerklizationDictionary;

pub fn loadStateDictionaryDump(allocator: Allocator, file_path: []const u8) !MerklizationDictionary {
    const slurp = @import("../../../utils/slurp.zig");
    // Read the JSON file
    var content = try slurp.slurpFile(allocator, file_path);
    defer content.deinit();

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content.buffer, .{});
    defer parsed.deinit();

    var dict = MerklizationDictionary.init(allocator);
    errdefer dict.deinit();

    // Extract keyvals array
    const root = parsed.value;
    const keyvals = root.object.get("keyvals").?.array;

    // Process each keyval pair
    for (keyvals.items) |pair| {
        const key = pair.array.items[0].string;
        const value = pair.array.items[1].string;

        // TODO: could be optimized by using fixed
        const key_bytes = try hex_bytes.hexStringToBytes(allocator, key[2..]);
        errdefer allocator.free(key_bytes);

        if (key_bytes.len != 32) {
            std.debug.print("Invalid key length: got {d} bytes, expected 32. Key hex: {s}\n", .{
                key_bytes.len,
                key,
            });
            return error.KeyError;
        }

        var key_array: [32]u8 = undefined;
        @memcpy(&key_array, key_bytes);
        allocator.free(key_bytes);

        // Alloc the value which will be owned by the dict
        const value_bytes = try hex_bytes.hexStringToBytes(allocator, value[2..]);
        try dict.entries.put(key_array, value_bytes);
    }

    return dict;
}
