const std = @import("std");
const types = @import("../../../types.zig");
const codec = @import("../../../codec.zig");
const state_dictionary = @import("../../../state_dictionary.zig");

const tracing = @import("../../../tracing.zig");
const codec_scope = tracing.scoped(.codec);

pub const KeyVal = struct {
    key: []const u8,
    val: []const u8,
    id: []const u8,
    desc: []const u8,

    pub fn decode(_: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
        const span = codec_scope.span(.keyval_decode);
        defer span.deinit();

        // Read key length and data
        const key_len = try codec.readInteger(reader);
        span.debug("Reading key of length: {d}", .{key_len});
        const key = try allocator.alloc(u8, @intCast(key_len));
        try reader.readNoEof(key);
        span.trace("Decoded key: {s}", .{std.fmt.fmtSliceHexLower(key)});

        // Read value length and data
        const val_len = try codec.readInteger(reader);
        span.debug("Reading value of length: {d}", .{val_len});
        const val = try allocator.alloc(u8, @intCast(val_len));
        try reader.readNoEof(val);
        span.trace("Decoded value: {s}", .{std.fmt.fmtSliceHexLower(val)});

        // Read id length and data
        const id_len = try codec.readInteger(reader);
        span.debug("Reading id of length: {d}", .{id_len});
        const id = try allocator.alloc(u8, @intCast(id_len));
        try reader.readNoEof(id);
        span.trace("Decoded id: {s}", .{std.fmt.fmtSliceHexLower(id)});

        // Read desc length and data
        const desc_len = try codec.readInteger(reader);
        span.debug("Reading desc of length: {d}", .{desc_len});
        const desc = try allocator.alloc(u8, @intCast(desc_len));
        try reader.readNoEof(desc);
        span.trace("Decoded desc: {s}", .{std.fmt.fmtSliceHexLower(desc)});

        span.debug("Successfully decoded KeyVal", .{});
        return KeyVal{
            .key = key,
            .val = val,
            .id = id,
            .desc = desc,
        };
    }

    // Add custom JSON serialization as array [key, val, id, desc]
    pub fn jsonStringify(self: *const KeyVal, writer: anytype) !void {
        try writer.beginArray();

        try writer.write(self.key);
        try writer.write(self.val);
        try writer.write(self.id);
        try writer.write(self.desc);

        try writer.endArray();
    }

    pub fn deinit(self: *KeyVal, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.val);
        allocator.free(self.id);
        allocator.free(self.desc);
        self.* = undefined;
    }
};

pub const StateSnapshotRaw = struct {
    state_root: types.StateRoot,
    keyvals: []KeyVal,

    pub fn deinit(self: *StateSnapshotRaw, allocator: std.mem.Allocator) void {
        for (self.keyvals) |*keyval| {
            keyval.deinit(allocator);
        }
        allocator.free(self.keyvals);
        self.* = undefined;
    }
};

pub const TestStateTransition = struct {
    pre_state: StateSnapshotRaw,
    block: types.Block,
    post_state: StateSnapshotRaw,

    pub fn deinit(self: *TestStateTransition, allocator: std.mem.Allocator) void {
        self.pre_state.deinit(allocator);
        self.block.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }

    pub fn preStateAsMerklizationDict(self: *const TestStateTransition, allocator: std.mem.Allocator) !state_dictionary.MerklizationDictionary {
        return keyValArrayToMerklizationDict(allocator, self.pre_state.keyvals, "pre_state");
    }

    pub fn postStateAsMerklizationDict(self: *const TestStateTransition, allocator: std.mem.Allocator) !state_dictionary.MerklizationDictionary {
        return keyValArrayToMerklizationDict(allocator, self.post_state.keyvals, "post_state");
    }

    pub fn validatePreStateRoot(self: *const TestStateTransition, allocator: std.mem.Allocator) !void {
        var state_mdict = try self.preStateAsMerklizationDict(allocator);
        defer state_mdict.deinit();
        const state_root = try state_mdict.buildStateRoot(allocator);

        try std.testing.expectEqualSlices(u8, &self.pre_state.state_root, &state_root);
    }

    pub fn validatePostStateRoot(self: *const TestStateTransition, allocator: std.mem.Allocator) !void {
        var state_mdict = try self.postStateAsMerklizationDict(allocator);
        defer state_mdict.deinit();
        const state_root = try state_mdict.buildStateRoot(allocator);

        try std.testing.expectEqualSlices(u8, &self.post_state.state_root, &state_root);
    }

    pub fn validateRoots(self: *const TestStateTransition, allocator: std.mem.Allocator) !void {
        try self.validatePreStateRoot(allocator);
        try self.validatePostStateRoot(allocator);
    }

    fn keyValArrayToMerklizationDict(allocator: std.mem.Allocator, keyvals: []const KeyVal, context: []const u8) !state_dictionary.MerklizationDictionary {
        var dict = state_dictionary.MerklizationDictionary.init(allocator);
        errdefer dict.deinit();

        for (keyvals) |keyval| {
            const key = keyValToKey(keyval.key) catch |err| {
                std.log.err("Invalid key length in {s} keyval: expected 32 bytes, got {d} bytes", .{ context, keyval.key.len });
                return err;
            };
            try dict.entries.put(key, try allocator.dupe(u8, keyval.val));
        }

        return dict;
    }

    fn keyValToKey(key_bytes: []const u8) !types.StateRoot {
        if (key_bytes.len != 32) {
            return error.InvalidKeyLength;
        }
        var key: types.OpaqueHash = undefined;
        std.mem.copyForwards(u8, &key, key_bytes[0..32]);
        return key;
    }
};

pub fn loadTestVector(
    comptime params: @import("../../../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !TestStateTransition {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const reader = file.reader();
    return try codec.deserializeAlloc(TestStateTransition, params, allocator, reader);
}
