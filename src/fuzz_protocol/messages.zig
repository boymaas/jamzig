const std = @import("std");
pub const codec = @import("../codec.zig");
const types = @import("../types.zig");
const constants = @import("constants.zig");
const jam_params = @import("../jam_params.zig");
const build_options = @import("build_options");

/// JAM parameters for fuzz protocol - configurable via build options
pub const FUZZ_PARAMS = if (@hasDecl(build_options, "conformance_params") and build_options.conformance_params == .tiny)
    jam_params.TINY_PARAMS
else
    jam_params.FULL_PARAMS;

pub const MAX_MESSAGE_SIZE: u32 = constants.MAX_MESSAGE_SIZE;

/// 31-byte trie key as specified in the protocol
pub const TrieKey = [31]u8;

pub const Hash = [32]u8;
pub const HeaderHash = Hash;
pub const StateRootHash = Hash;
pub const TimeSlot = u32;

/// Feature flags for protocol capabilities
pub const Features = u32;

/// Feature flag constants
pub const FEATURE_ANCESTRY: Features = 1; // 2^0
pub const FEATURE_FORK: Features = 2; // 2^1
pub const FEATURE_RESERVED: Features = 2147483648; // 2^31

/// Version information for protocol versioning
pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,
};

/// Peer information exchanged during handshake (v1 format)
pub const PeerInfo = struct {
    fuzz_version: u8,
    fuzz_features: Features,
    jam_version: Version,
    app_version: Version,
    app_name: []const u8,

    // Static constructor for PeerInfo
    pub fn buildFromStaticString(
        allocator: std.mem.Allocator,
        fuzz_version: u8,
        fuzz_features: Features,
        jam_version: Version,
        app_version: Version,
        app_name: []const u8,
    ) !PeerInfo {
        const name_bytes = try allocator.dupe(u8, app_name);
        return PeerInfo{
            .fuzz_version = fuzz_version,
            .fuzz_features = fuzz_features,
            .jam_version = jam_version,
            .app_version = app_version,
            .app_name = name_bytes,
        };
    }

    pub fn deinit(self: *PeerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.app_name);
        self.* = undefined;
    }
};

/// Key-value pair for state representation
pub const KeyValue = struct {
    key: TrieKey,
    value: []const u8,
};

/// State as a sequence of key-value pairs
pub const State = struct {
    items: []const KeyValue,

    pub const Empty = State{ .items = &[_]KeyValue{} };

    /// Free all allocated memory for the state
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.items) |kv| {
            allocator.free(kv.value);
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Block import message using complex JAM types
pub const ImportBlock = types.Block;

/// Ancestry item for tracking block chain history
pub const AncestryItem = struct {
    slot: TimeSlot,
    header_hash: HeaderHash,
};

/// Ancestry sequence (up to 24 items for tiny spec)
pub const Ancestry = struct {
    items: []const AncestryItem,

    pub const Empty = Ancestry{ .items = &[_]AncestryItem{} };

    pub fn deinit(self: *Ancestry, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Initialize message replacing SetState (v1)
pub const Initialize = struct {
    header: types.Header,
    keyvals: State,
    ancestry: Ancestry,

    pub fn deinit(self: *Initialize, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        self.keyvals.deinit(allocator);
        self.ancestry.deinit(allocator);
        self.* = undefined;
    }
};

/// Get state request by header hash
pub const GetState = HeaderHash;

/// State root response
pub const StateRoot = StateRootHash;

/// Error message with UTF8 string
pub const Error = []const u8;

pub const MessageType = enum(u8) {
    peer_info = 0,
    initialize = 1,
    state_root = 2,
    import_block = 3,
    get_state = 4,
    state = 5,
    kill = 254,
    @"error" = 255,
};

/// Protocol message enumeration (v1 format)
pub const Message = union(MessageType) {
    peer_info: PeerInfo,
    initialize: Initialize,
    state_root: StateRoot,
    import_block: ImportBlock,
    get_state: GetState,
    state: State,
    kill: void,
    @"error": Error,

    /// Free any allocated memory for this message
    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .state => |*state| {
                state.deinit(allocator);
            },
            .peer_info => |*peer_info| {
                peer_info.deinit(allocator);
            },
            .import_block => |*block| {
                block.deinit(allocator);
            },
            .initialize => |*initialize| {
                initialize.deinit(allocator);
            },
            .@"error" => |error_msg| {
                allocator.free(error_msg);
            },
            .get_state,
            .state_root,
            .kill,
            => {},
        }
        self.* = undefined;
    }

    /// Custom encode method for v1 protocol (single-byte discriminant)
    pub fn encode(self: *const Message, comptime params: anytype, writer: anytype) !void {

        // Write discriminant as single byte (not varint)
        const discriminant: u8 = @intFromEnum(std.meta.activeTag(self.*));
        try writer.writeByte(discriminant);

        // Serialize payload based on message type
        switch (self.*) {
            .peer_info => |peer_info| {
                try codec.serialize(PeerInfo, params, writer, peer_info);
            },
            .initialize => |initialize| {
                try codec.serialize(Initialize, params, writer, initialize);
            },
            .state_root => |state_root| {
                try codec.serialize(StateRoot, params, writer, state_root);
            },
            .import_block => |import_block| {
                try codec.serialize(ImportBlock, params, writer, import_block);
            },
            .get_state => |get_state| {
                try codec.serialize(GetState, params, writer, get_state);
            },
            .state => |state| {
                try codec.serialize(State, params, writer, state);
            },
            .kill => {
                // void type - no payload to serialize
            },
            .@"error" => |error_msg| {
                try codec.serialize(Error, params, writer, error_msg);
            },
        }
    }

    /// Custom decode method for v1 protocol (single-byte discriminant)
    pub fn decode(comptime params: anytype, reader: anytype, allocator: std.mem.Allocator) !Message {

        // Read discriminant as single byte (not varint)
        const discriminant = try reader.readByte();

        // Deserialize payload based on discriminant value
        return switch (discriminant) {
            0 => {
                const peer_info = try codec.deserializeAlloc(PeerInfo, params, allocator, reader);
                return Message{ .peer_info = peer_info };
            },
            1 => {
                const initialize = try codec.deserializeAlloc(Initialize, params, allocator, reader);
                return Message{ .initialize = initialize };
            },
            2 => {
                const state_root = try codec.deserializeAlloc(StateRoot, params, allocator, reader);
                return Message{ .state_root = state_root };
            },
            3 => {
                const import_block = try codec.deserializeAlloc(ImportBlock, params, allocator, reader);
                return Message{ .import_block = import_block };
            },
            4 => {
                const get_state = try codec.deserializeAlloc(GetState, params, allocator, reader);
                return Message{ .get_state = get_state };
            },
            5 => {
                const state = try codec.deserializeAlloc(State, params, allocator, reader);
                return Message{ .state = state };
            },
            254 => {
                return Message{ .kill = {} };
            },
            255 => {
                const error_msg = try codec.deserializeAlloc(Error, params, allocator, reader);
                return Message{ .@"error" = error_msg };
            },
            else => {
                return codec.DeserializationError.InvalidUnionTagValue;
            },
        };
    }
};

/// Encode a message using JAM codec
pub fn encodeMessage(allocator: std.mem.Allocator, message: Message) ![]u8 {
    return try codec.serializeAlloc(Message, FUZZ_PARAMS, allocator, message);
}

/// Decode a message from bytes using JAM codec
pub fn decodeMessage(allocator: std.mem.Allocator, data: []const u8) !Message {
    var stream = std.io.fixedBufferStream(data);
    return try codec.deserializeAlloc(Message, FUZZ_PARAMS, allocator, stream.reader());
}
