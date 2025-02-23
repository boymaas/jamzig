const std = @import("std");
const types = @import("../types.zig");
const state_dictionary = @import("../state_dictionary.zig");

pub const KeyVal = struct {
    key: [32]u8,
    val: []const u8,
    metadata: ?state_dictionary.DictMetadata,

    // Add custom JSON serialization as array [key, val, id, desc]
    pub fn jsonStringify(self: *const KeyVal, writer: anytype) !void {
        try writer.beginArray();

        try writer.write(self.key);
        try writer.write(self.val);

        if (self.metadata) |mdata| {
            try writer.write(mdata);
        }

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

    pub fn deinit(self: *StateTransition, allocator: std.mem.Allocator) void {
        self.pre_state.deinit(allocator);
        self.block.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }
};
