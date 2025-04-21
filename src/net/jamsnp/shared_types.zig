const std = @import("std");
const uuid = @import("uuid");
const network = @import("network");

pub const ConnectionId = uuid.Uuid;
pub const StreamId = uuid.Uuid;

// -- Client Callback Types
pub const ClientEventType = enum {
    ConnectionEstablished,
    ConnectionFailed,
    ConnectionClosed,
    StreamCreated,
    StreamClosed,
    DataReceived,
    DataEndOfStream,
    DataReadError,
    DataWouldBlock,
    DataWriteProgress,
    DataWriteCompleted,
    DataWriteError,
};

pub const ClientConnectionEstablishedCallbackFn = *const fn (connection: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) void;
pub const ClientConnectionFailedCallbackFn = *const fn (endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) void;
pub const ClientConnectionClosedCallbackFn = *const fn (connection: ConnectionId, context: ?*anyopaque) void;
pub const ClientStreamCreatedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
pub const ClientStreamClosedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
pub const ClientDataReceivedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, data: []const u8, context: ?*anyopaque) void;
pub const ClientDataEndOfStreamCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, data_read: []const u8, context: ?*anyopaque) void;
pub const ClientDataErrorCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, error_code: i32, context: ?*anyopaque) void;
pub const ClientDataWouldBlockCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
pub const ClientDataWriteProgressCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, bytes_written: usize, total_size: usize, context: ?*anyopaque) void;
pub const ClientDataWriteCompletedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, total_bytes_written: usize, context: ?*anyopaque) void;

// -- Server Callback Types
pub const ServerEventType = enum {
    ClientConnected,
    ClientDisconnected,
    StreamCreatedByClient,
    StreamClosedByClient,
    DataReceived,
    DataWriteCompleted,
    DataReadError,
    DataWriteError,
    DataReadWouldBlock,
    DataWriteWouldBlock,
};

pub const ServerClientConnectedCallbackFn = *const fn (connection_id: ConnectionId, peer_addr: std.net.Address, context: ?*anyopaque) void;
pub const ServerClientDisconnectedCallbackFn = *const fn (connection_id: ConnectionId, context: ?*anyopaque) void;
pub const ServerStreamCreatedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void;
pub const ServerStreamClosedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void;
pub const ServerDataReceivedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, data: []const u8, context: ?*anyopaque) void;
pub const ServerDataWriteCompletedCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, total_bytes_written: usize, context: ?*anyopaque) void;
pub const ServerDataErrorCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, error_code: i32, context: ?*anyopaque) void;
pub const ServerDataWouldBlockCallbackFn = *const fn (connection_id: ConnectionId, stream_id: StreamId, context: ?*anyopaque) void;

// -- Common Callback Handler
pub const CallbackHandler = struct {
    callback: ?*const anyopaque,
    context: ?*anyopaque,
};
