const std = @import("std");
const types = @import("../types.zig");

const jam_params = @import("../jam_params.zig");

const state = @import("../state.zig");
const testnet_json = @import("json.zig");
const codec = @import("../codec.zig");
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

    pub fn exportToFormat(
        self: *const StateSnapshot,
        allocator: std.mem.Allocator,
        format: export_format.Format,
        config: export_format.Config,
    ) ![]u8 {
        switch (format) {
            .json => {
                var list = std.ArrayList(u8).init(allocator);
                errdefer list.deinit();

                try testnet_json.stringify(
                    self.*,
                    .{
                        .whitespace = config.json_whitespace,
                        .emit_strings_as_arrays = config.json_strings_as_arrays,
                        .emit_bytes_as_hex = config.json_bytes_as_hex,
                    },
                    list.writer(),
                );
                return list.toOwnedSlice();
            },
            .binary => {
                return try codec.serializeAlloc(StateSnapshot, {}, allocator, self.*);
            },
        }
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

            // Create DictEntry with proper metadata
            try dict.entries.put(key, .{
                .key = key,
                .value = try allocator.dupe(u8, keyval.val),
                .metadata = keyval.metadata,
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

    pub fn exportToFormat(
        self: *const StateTransition,
        allocator: std.mem.Allocator,
        format: export_format.Format,
        config: export_format.Config,
    ) ![]u8 {
        switch (format) {
            .json => {
                var list = std.ArrayList(u8).init(allocator);
                errdefer list.deinit();

                try testnet_json.stringify(
                    self.*,
                    .{
                        .whitespace = config.json_whitespace,
                        .emit_strings_as_arrays = config.json_strings_as_arrays,
                        .emit_bytes_as_hex = config.json_bytes_as_hex,
                    },
                    list.writer(),
                );
                return list.toOwnedSlice();
            },
            .binary => {
                return try codec.serializeAlloc(StateTransition, {}, allocator, self.*);
            },
        }
    }

    pub fn writeToFile(
        self: *const StateTransition,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        filename: []const u8,
        format: export_format.Format,
        config: export_format.Config,
    ) !void {
        try std.fs.cwd().makePath(dir_path);

        const ext = switch (format) {
            .json => ".json",
            .binary => ".bin",
        };

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir_path, filename, ext });
        defer allocator.free(path);

        const data = try self.exportToFormat(allocator, format, config);
        defer allocator.free(data);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(data);
    }
};

pub const export_format = struct {
    pub const Format = enum {
        json,
        binary,
    };

    pub const Config = struct {
        json_whitespace: testnet_json.StringifyOptions.whitespace = .indent_2,
        json_strings_as_arrays: bool = false,
        json_bytes_as_hex: bool = true,
    };
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
            .metadata = dict_entry.metadata,
        });
    }

    std.mem.sort(KeyVal, keyvals.items, {}, struct {
        fn lessThan(_: void, a: KeyVal, b: KeyVal) bool {
            return std.mem.lessThan(u8, &a.key, &b.key);
        }
    }.lessThan);

    return keyvals.toOwnedSlice();
}

pub fn writeStateTransition(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    transition: StateTransition,
    output_dir: []const u8,
) !void {
    // Create base paths
    const epoch = transition.block.header.slot / params.epoch_length;
    const slot_in_epoch = transition.block.header.slot % params.epoch_length;

    // Create filenames
    const bin_path_buf = try std.fmt.allocPrint(allocator, "{s}/{:0>4}_{:0>4}.bin", .{
        output_dir, epoch, slot_in_epoch,
    });
    defer allocator.free(bin_path_buf);

    const json_path_buf = try std.fmt.allocPrint(allocator, "{s}/{:0>4}_{:0>4}.json", .{
        output_dir, epoch, slot_in_epoch,
    });
    defer allocator.free(json_path_buf);

    // Create output directory if it doesn't exist
    try std.fs.cwd().makePath(output_dir);

    // Write binary format
    {
        const file = try std.fs.cwd().createFile(bin_path_buf, .{});
        defer file.close();
        try codec.serialize(StateTransition, params, file.writer(), transition);
    }

    // Write JSON format
    {
        const file = try std.fs.cwd().createFile(json_path_buf, .{});
        defer file.close();

        try testnet_json.stringify(
            transition,
            .{
                .whitespace = .indent_2,
                .emit_strings_as_arrays = false,
                .emit_bytes_as_hex = true,
            },
            file.writer(),
        );
    }
}
