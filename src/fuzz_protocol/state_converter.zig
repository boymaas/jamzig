const std = @import("std");
const messages = @import("messages.zig");
const state_dictionary = @import("../state_dictionary.zig");
const jam_state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

/// Result type for jamStateToFuzzState that manages memory automatically
pub const FuzzStateResult = struct {
    state: messages.State,
    root: messages.StateRootHash,
    allocator: std.mem.Allocator,

    /// Intermediate state for building the result
    const Builder = struct {
        list: std.ArrayList(messages.KeyValue),
        allocator: std.mem.Allocator,
        root: messages.StateRootHash = undefined,

        fn deinit(self: *Builder) void {
            // Clean up any allocated values
            for (self.list.items) |kv| {
                self.allocator.free(kv.value);
            }
            self.list.deinit();
        }

        /// Append a key-value pair, copying the value
        fn append(self: *Builder, key: messages.TrieKey, value: []const u8) !void {
            self.list.appendAssumeCapacity(.{
                .key = key,
                .value = value,
            });
        }

        fn finalize(self: *Builder, root: messages.StateRootHash) !FuzzStateResult {
            self.root = root;
            const items = try self.list.toOwnedSlice();
            return FuzzStateResult{
                .state = messages.State{ .items = items },
                .root = root,
                .allocator = self.allocator,
            };
        }
    };

    /// Initialize with known capacity to avoid reallocations
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Builder {
        var list = std.ArrayList(messages.KeyValue).init(allocator);
        try list.ensureTotalCapacity(capacity);
        return Builder{
            .list = list,
            .allocator = allocator,
        };
    }

    /// Free all allocated memory
    pub fn deinit(self: *FuzzStateResult) void {
        self.state.deinit(self.allocator);
    }
};

/// Converts a JAM state to fuzz protocol State format (array of KeyValue pairs)
///
/// This function:
/// 1. Builds a merklization dictionary from the JAM state
/// 2. Converts it to an array of KeyValue pairs
/// 3. Returns both the state and its merkle root
///
/// The returned FuzzStateResult manages all memory and should be deinitialized
pub fn jamStateToFuzzState(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    state: *const jam_state.JamState(params),
) !FuzzStateResult {
    // Build the merklization dictionary
    var dict = try state_dictionary.buildStateMerklizationDictionary(params, allocator, state);
    defer dict.deinit();

    // Calculate the state root
    const root = try dict.buildStateRoot(allocator);

    // Convert to KeyValue array
    const kv_array = try dict.toKeyValueArrayOwned();
    defer allocator.free(kv_array);

    // Convert to messages.State format using capacity-hinted builder
    // We need to convert from the anonymous struct to messages.KeyValue
    // and make copies of the values since the dict will be freed
    var builder = try FuzzStateResult.initCapacity(allocator, kv_array.len);
    errdefer builder.deinit();

    for (kv_array) |kv| {
        try builder.append(kv.key, kv.value);
    }

    return try builder.finalize(root);
}

/// Converts a MerklizationDictionary to fuzz protocol State format
/// The caller owns the returned array and must free it. Values are owned by the dictionary.
pub fn dictionaryToFuzzState(
    allocator: std.mem.Allocator,
    dict: *const state_dictionary.MerklizationDictionary,
) !messages.State {
    // Convert to KeyValue array
    const kv_array = try dict.toKeyValueArrayOwned();
    defer allocator.free(kv_array);

    // Convert to messages.State format
    var state_array = try allocator.alloc(messages.KeyValue, kv_array.len);
    errdefer allocator.free(state_array);

    for (kv_array, 0..) |kv, i| {
        state_array[i] = .{
            .key = kv.key,
            .value = kv.value,
        };
    }

    return messages.State{ .items = state_array };
}

/// Builds a MerklizationDictionary from fuzz protocol State format
/// The returned dictionary owns all the values
pub fn fuzzStateToMerklizationDictionary(
    allocator: std.mem.Allocator,
    state: messages.State,
) !state_dictionary.MerklizationDictionary {
    var dict = state_dictionary.MerklizationDictionary.init(allocator);
    errdefer dict.deinit();

    for (state.items) |kv| {
        // Create a copy of the value since the dictionary takes ownership
        const value_copy = try allocator.dupe(u8, kv.value);
        errdefer allocator.free(value_copy);

        try dict.put(.{
            .key = kv.key,
            .value = value_copy,
        });
    }

    return dict;
}

/// Converts fuzz protocol State format directly to JAM state
/// This is a convenience function that combines dictionary building and state reconstruction
pub fn fuzzStateToJamState(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    state: messages.State,
) !jam_state.JamState(params) {
    // Build merklization dictionary from fuzz state
    var dict = try fuzzStateToMerklizationDictionary(allocator, state);
    defer dict.deinit();

    // Reconstruct JAM state from dictionary
    const state_reconstruct = @import("../state_dictionary/reconstruct.zig");
    return try state_reconstruct.reconstructState(params, allocator, &dict);
}
