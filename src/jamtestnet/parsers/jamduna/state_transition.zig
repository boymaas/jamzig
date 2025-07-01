const std = @import("std");
const types = @import("../../../types.zig");
const codec = @import("../../../codec.zig");
const state_dictionary = @import("../../../state_dictionary.zig");

const tracing = @import("../../../tracing.zig");
const codec_scope = tracing.scoped(.codec);

const PreimageLookupInfo = struct {
    hash: [32]u8,
    length: u32,
};

/// Find and parse the length part that starts with "l="
fn parseLengthFromDesc(desc: []const u8) !u32 {
    const len_prefix = "l=";
    const len_start = std.mem.indexOf(u8, desc, len_prefix) orelse return error.InvalidDescFormat;
    const num_start = len_start + len_prefix.len;

    // Find the end of the length (at | or end of string)
    const num_end = std.mem.indexOfScalar(u8, desc[num_start..], '|') orelse desc.len;
    const num_string = desc[num_start..][0..num_end];

    // Parse the length as an integer
    const length = try std.fmt.parseInt(u32, num_string, 10);

    return length;
}

fn parseKFromDesc(desc: []const u8) ![32]u8 {
    // std.debug.print("{s}", .{desc});
    const k_prefix = " k=0x";
    const k_start = std.mem.indexOf(u8, desc, k_prefix) orelse return error.InvalidDescFormat;
    const hex_start = k_start + k_prefix.len;

    const hex_string = desc[hex_start..][0..64];
    // std.debug.print("{s}\n", .{hex_string});

    // Parse the hex string into bytes
    var masked_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&masked_bytes, hex_string);
    return masked_bytes;
}

/// Find the hash part that starts with "h=0x"
fn parseHKFromDesc(desc: []const u8) ![32]u8 {
    const hash_prefix = "hk=0x";
    const hash_start = std.mem.indexOf(u8, desc, hash_prefix) orelse {
        std.debug.print("Invalid format: {s}\n", .{desc});
        return error.InvalidDescFormat;
    };
    const hex_start = hash_start + hash_prefix.len;

    const hex_string = desc[hex_start..][0..64];

    // Parse the hex string into bytes
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hex_string) catch {
        std.debug.print("Failed to parse hex string: '{s}' (len={d})\n", .{
            hex_string,
            hex_string.len,
        });
        return error.InvalidHexFormat;
    };
    return hash;
}

/// Find the hash part that starts with "h=0x"
fn parseHashFromDesc(desc: []const u8) ![32]u8 {
    const hash_prefix = "h=0x";
    const hash_start = std.mem.indexOf(u8, desc, hash_prefix) orelse {
        std.debug.print("Invalid format: {s}\n", .{desc});
        return error.InvalidDescFormat;
    };
    const hex_start = hash_start + hash_prefix.len;

    const hex_string = desc[hex_start..][0..64];

    // Parse the hex string into bytes
    var hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash, hex_string);
    return hash;
}

pub const KeyVal = struct {
    key: []const u8,
    val: []const u8,
    id: []const u8,
    desc: []const u8,

    pub fn getKey(self: *const @This()) types.StateKey {
        return self.key[0..31].*;
    }

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

    pub fn parseMetadata(self: *const @This()) !?state_dictionary.DictMetadata {
        // Determine metadata type using key_type_detection
        const key = self.getKey();
        const key_type = state_dictionary.reconstruct.detectKeyType(key);
        return switch (key_type) {
            .delta_storage => blk: {
                const storage_key = try parseKFromDesc(self.desc);

                break :blk state_dictionary.DictMetadata{
                    .delta_storage = .{
                        .storage_key = storage_key,
                    },
                };
            },
            .delta_preimage => blk: {
                const hash = try parseHashFromDesc(self.desc);

                break :blk state_dictionary.DictMetadata{
                    .delta_preimage = .{
                        .hash = hash,
                        .preimage_length = @intCast(self.val.len),
                    },
                };
            },
            .delta_preimage_lookup => blk: {
                break :blk state_dictionary.DictMetadata{
                    .delta_preimage_lookup = .{
                        .hash = try parseHashFromDesc(self.desc),
                        .preimage_length = try parseLengthFromDesc(self.desc),
                    },
                };
            },
            else => null,
        };
    }

    // Add custom JSON serialization as array [key, val, id, desc]
    pub fn jsonStringify(self: *const KeyVal, writer: anytype) !void {
        try writer.beginArray();

        try writer.write(self.key);
        try writer.write(self.val);

        writer.options.emit_bytes_as_hex = false;
        try writer.write(self.id);
        try writer.write(self.desc);
        writer.options.emit_bytes_as_hex = true;

        try writer.write(self.metadata);

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

    pub fn deinitHeap(self: *TestStateTransition, allocator: std.mem.Allocator) void {
        self.pre_state.deinit(allocator);
        self.block.deinit(allocator);
        self.post_state.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn preStateAsMerklizationDict(self: *const TestStateTransition, allocator: std.mem.Allocator) !state_dictionary.MerklizationDictionary {
        return keyValArrayToMerklizationDict(allocator, self.pre_state.keyvals, "pre_state");
    }

    pub fn postStateAsMerklizationDict(self: *const TestStateTransition, allocator: std.mem.Allocator) !state_dictionary.MerklizationDictionary {
        return keyValArrayToMerklizationDict(allocator, self.post_state.keyvals, "post_state");
    }

    pub fn preStateRoot(self: *const TestStateTransition) types.StateRoot {
        return self.pre_state.state_root;
    }

    pub fn postStateRoot(self: *const TestStateTransition) types.StateRoot {
        return self.post_state.state_root;
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

            // Create DictEntry with proper metadata
            try dict.entries.put(key, .{
                .key = key,
                .value = try allocator.dupe(u8, keyval.val),
                .metadata = try keyval.parseMetadata(),
            });
        }

        return dict;
    }

    fn keyValToKey(key_bytes: []const u8) !types.StateKey {
        if (key_bytes.len != 32) {
            return error.InvalidKeyLength;
        }
        var key: types.StateKey = undefined;
        std.mem.copyForwards(u8, &key, key_bytes[0..31]);
        return key;
    }
};

pub fn loadTestVector(
    comptime params: @import("../../../jam_params.zig").Params,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !codec.Deserialized(TestStateTransition) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const reader = file.reader();
    return try codec.deserialize(TestStateTransition, params, allocator, reader);
}
