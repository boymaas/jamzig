const std = @import("std");
const messages = @import("messages.zig");
const state_dictionary = @import("../state_dictionary.zig");
const jam_state = @import("../state.zig");
const jam_params = @import("../jam_params.zig");

pub const FuzzStateResult = struct {
    state: messages.State,
    root: messages.StateRootHash,
    allocator: std.mem.Allocator,

    const Builder = struct {
        list: std.ArrayList(messages.KeyValue),
        allocator: std.mem.Allocator,
        root: messages.StateRootHash = undefined,

        fn deinit(self: *Builder) void {
            for (self.list.items) |kv| {
                self.allocator.free(kv.value);
            }
            self.list.deinit();
        }

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

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Builder {
        var list = std.ArrayList(messages.KeyValue).init(allocator);
        try list.ensureTotalCapacity(capacity);
        return Builder{
            .list = list,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FuzzStateResult) void {
        self.state.deinit(self.allocator);
    }
};

pub fn jamStateToFuzzState(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    state: *const jam_state.JamState(params),
) !FuzzStateResult {
    var dict = try state_dictionary.buildStateMerklizationDictionary(params, allocator, state);
    defer dict.deinit();

    const root = try dict.buildStateRoot(allocator);

    const kv_array = try dict.toKeyValueArrayOwned();
    defer allocator.free(kv_array);

    var builder = try FuzzStateResult.initCapacity(allocator, kv_array.len);
    errdefer builder.deinit();

    for (kv_array) |kv| {
        try builder.append(kv.key, kv.value);
    }

    return try builder.finalize(root);
}

pub fn dictionaryToFuzzState(
    allocator: std.mem.Allocator,
    dict: *const state_dictionary.MerklizationDictionary,
) !messages.State {
    const kv_array = try dict.toKeyValueArrayOwned();
    defer allocator.free(kv_array);

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

pub fn fuzzStateToMerklizationDictionary(
    allocator: std.mem.Allocator,
    state: messages.State,
) !state_dictionary.MerklizationDictionary {
    var dict = state_dictionary.MerklizationDictionary.init(allocator);
    errdefer dict.deinit();

    for (state.items) |kv| {
        const value_copy = try allocator.dupe(u8, kv.value);
        errdefer allocator.free(value_copy);

        try dict.put(.{
            .key = kv.key,
            .value = value_copy,
        });
    }

    return dict;
}

pub fn fuzzStateToJamState(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    state: messages.State,
) !jam_state.JamState(params) {
    var dict = try fuzzStateToMerklizationDictionary(allocator, state);
    defer dict.deinit();

    const state_reconstruct = @import("../state_dictionary/reconstruct.zig");
    return try state_reconstruct.reconstructState(params, allocator, &dict);
}
