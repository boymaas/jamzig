const std = @import("std");
pub const codec = @import("../codec.zig");
const types = @import("../types.zig");
const constants = @import("constants.zig");
const jam_params = @import("../jam_params.zig");

/// JAM parameters for fuzz protocol - using TINY_PARAMS for simpler testing
pub const FUZZ_PARAMS = jam_params.TINY_PARAMS;
pub const MAX_MESSAGE_SIZE: u32 = constants.MAX_MESSAGE_SIZE;

/// 31-byte trie key as specified in the protocol
pub const TrieKey = [31]u8;

pub const Hash = [32]u8;
pub const HeaderHash = Hash;
pub const StateRootHash = Hash;

/// Version information for protocol versioning
pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,
};

/// Peer information exchanged during handshake
pub const PeerInfo = struct {
    name: []const u8,
    version: Version,
    protocol_version: Version,
};

/// Key-value pair for state representation
pub const KeyValue = struct {
    key: TrieKey,
    value: []const u8,
};

/// State as a sequence of key-value pairs
pub const State = []const KeyValue;

/// Block import message using complex JAM types
pub const ImportBlock = types.Block;

/// Set state message with header and full state
pub const SetState = struct {
    header: types.Header,
    state: State,
};

/// Get state request by header hash
pub const GetState = HeaderHash;

/// State root response
pub const StateRoot = StateRootHash;

/// Protocol message enumeration
pub const Message = union(enum) {
    peer_info: PeerInfo,
    import_block: ImportBlock,
    set_state: SetState,
    get_state: GetState,
    state: State,
    state_root: StateRoot,
    kill: void,
};

/// Encode a message using JAM codec
pub fn encodeMessage(allocator: std.mem.Allocator, message: Message) ![]u8 {
    var encoded_content = std.ArrayList(u8).init(allocator);
    defer encoded_content.deinit();

    return try codec.serializeAlloc(Message, FUZZ_PARAMS, allocator, message);
}

/// Decode a message from bytes using JAM codec
pub fn decodeMessage(allocator: std.mem.Allocator, data: []const u8) !codec.Deserialized(Message) {
    var stream = std.io.fixedBufferStream(data);
    return try codec.deserialize(Message, FUZZ_PARAMS, allocator, stream.reader());
}
