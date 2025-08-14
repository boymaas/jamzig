const std = @import("std");
const types = @import("../types.zig");

const jam_params = @import("../jam_params.zig");

const state = @import("../state.zig");
const codec = @import("../codec.zig");
const state_dictionary = @import("../state_dictionary.zig");

pub const KeyVal = struct {
    key: types.StateKey,
    val: []const u8,

    // Add custom JSON serialization as array [key, val, id, desc]
    pub fn jsonStringify(self: *const KeyVal, writer: anytype) !void {
        try writer.beginArray();

        try writer.write(self.key);
        try writer.write(self.val);

        try writer.endArray();
    }

    pub fn deinit(self: *KeyVal, allocator: std.mem.Allocator) void {
        allocator.free(self.val);
        self.* = undefined;
    }
};

pub const StateSnapshot = struct {
    state_root: types.StateRoot,
    keyvals: []KeyVal,

    pub fn init(comptime params: anytype, allocator: std.mem.Allocator, current_state: *const state.JamState(params)) !StateSnapshot {
        return .{
            .state_root = try current_state.buildStateRoot(allocator),
            .keyvals = try buildKeyValsFromState(params, allocator, current_state),
        };
    }

    pub fn deinit(self: *StateSnapshot, allocator: std.mem.Allocator) void {
        for (self.keyvals) |*keyval| {
            keyval.deinit(allocator);
        }
        allocator.free(self.keyvals);
        self.* = undefined;
    }
};

pub const StateTransition = struct {
    pre_state: StateSnapshot,
    block: types.Block,
    post_state: StateSnapshot,

    pub fn init(
        comptime params: anytype,
        allocator: std.mem.Allocator,
        current_state: *const state.JamState(params),
        block: types.Block,
        next_state: *const state.JamState(params),
    ) !StateTransition {
        return .{
            .pre_state = try StateSnapshot.init(params, allocator, current_state),
            .block = try block.deepClone(allocator),
            .post_state = try StateSnapshot.init(params, allocator, next_state),
        };
    }

    pub fn preStateAsMerklizationDict(self: *const @This(), allocator: std.mem.Allocator) !state_dictionary.MerklizationDictionary {
        return keyValArrayToMerklizationDict(allocator, self.pre_state.keyvals, "pre_state");
    }

    pub fn postStateAsMerklizationDict(self: *const @This(), allocator: std.mem.Allocator) !state_dictionary.MerklizationDictionary {
        return keyValArrayToMerklizationDict(allocator, self.post_state.keyvals, "post_state");
    }

    pub fn preStateRoot(self: *const @This()) types.StateRoot {
        return self.pre_state.state_root;
    }

    pub fn postStateRoot(self: *const @This()) types.StateRoot {
        return self.post_state.state_root;
    }

    pub fn validatePreStateRoot(self: *const @This(), allocator: std.mem.Allocator) !void {
        var state_mdict = try self.preStateAsMerklizationDict(allocator);
        defer state_mdict.deinit();
        const state_root = try state_mdict.buildStateRoot(allocator);

        try std.testing.expectEqualSlices(u8, &self.pre_state.state_root, &state_root);
    }

    pub fn validatePostStateRoot(self: *const @This(), allocator: std.mem.Allocator) !void {
        var state_mdict = try self.postStateAsMerklizationDict(allocator);
        defer state_mdict.deinit();
        const state_root = try state_mdict.buildStateRoot(allocator);

        try std.testing.expectEqualSlices(u8, &self.post_state.state_root, &state_root);
    }

    pub fn validateRoots(self: *const @This(), allocator: std.mem.Allocator) !void {
        try self.validatePreStateRoot(allocator);
        try self.validatePostStateRoot(allocator);
    }

    fn keyValToKey(key_bytes: []const u8) !types.OpaqueHash {
        if (key_bytes.len != 32) {
            return error.InvalidKeyLength;
        }
        var key: types.OpaqueHash = undefined;
        std.mem.copyForwards(u8, &key, key_bytes[0..32]);
        return key;
    }

    fn keyValArrayToMerklizationDict(allocator: std.mem.Allocator, keyvals: []const KeyVal, _: []const u8) !state_dictionary.MerklizationDictionary {
        var dict = state_dictionary.MerklizationDictionary.init(allocator);
        errdefer dict.deinit();

        for (keyvals) |keyval| {
            const key = keyval.key;

            try dict.entries.put(key, .{
                .key = key,
                .value = try allocator.dupe(u8, keyval.val),
            });
        }

        return dict;
    }

    pub fn deinit(self: *StateTransition, allocator: std.mem.Allocator) void {
        self.pre_state.deinit(allocator);
        self.block.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }

    pub fn deinitHeap(self: *StateTransition, allocator: std.mem.Allocator) void {
        self.pre_state.deinit(allocator);
        self.block.deinit(allocator);
        self.post_state.deinit(allocator);
        allocator.destroy(self);
    }
};

pub fn buildStateTransition(
    comptime params: anytype,
    allocator: std.mem.Allocator,
    pre_state: *const state.JamState(params),
    block: types.Block,
    post_state: *const state.JamState(params),
) !StateTransition {
    return StateTransition{
        .pre_state = .{
            .state_root = try pre_state.buildStateRoot(allocator),
            .keyvals = try buildKeyValsFromState(params, allocator, pre_state),
        },
        .block = try block.deepClone(allocator),
        .post_state = .{
            .state_root = try post_state.buildStateRoot(allocator),
            .keyvals = try buildKeyValsFromState(params, allocator, post_state),
        },
    };
}

fn buildKeyValsFromState(
    comptime params: anytype,
    allocator: std.mem.Allocator,
    current_state: *const state.JamState(params),
) ![]KeyVal {
    var mdict = try current_state.buildStateMerklizationDictionary(allocator);
    defer mdict.deinit();

    var entries = mdict.entries.iterator();
    var keyvals = try std.ArrayList(KeyVal).initCapacity(allocator, mdict.entries.count());
    defer keyvals.deinit();

    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        const dict_entry = entry.value_ptr.*;
        try keyvals.append(.{
            .key = key,
            .val = try allocator.dupe(u8, dict_entry.value),
        });
    }

    std.mem.sort(KeyVal, keyvals.items, {}, struct {
        fn lessThan(_: void, a: KeyVal, b: KeyVal) bool {
            return std.mem.lessThan(u8, &a.key, &b.key);
        }
    }.lessThan);

    return keyvals.toOwnedSlice();
}
