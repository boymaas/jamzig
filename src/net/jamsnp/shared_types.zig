const std = @import("std");
const uuid = @import("uuid");
const network = @import("network");

pub const ConnectionId = uuid.Uuid;
pub const StreamId = uuid.Uuid;

// -- Client Callback Types
pub const EventType = enum {
    ClientConnected,
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

pub const ClientConnectedCallbackFn = *const fn (connection: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) void;
pub const ConnectionEstablishedCallbackFn = *const fn (connection: ConnectionId, endpoint: network.EndPoint, context: ?*anyopaque) void;
pub const ConnectionFailedCallbackFn = *const fn (endpoint: network.EndPoint, err: anyerror, context: ?*anyopaque) void;
pub const ConnectionClosedCallbackFn = *const fn (connection: ConnectionId, context: ?*anyopaque) void;
pub const StreamCreatedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
pub const StreamClosedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
pub const DataReceivedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, data: []const u8, context: ?*anyopaque) void;
pub const DataEndOfStreamCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, data_read: []const u8, context: ?*anyopaque) void;
pub const DataErrorCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, error_code: i32, context: ?*anyopaque) void;
pub const DataWouldBlockCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, context: ?*anyopaque) void;
pub const DataWriteProgressCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, bytes_written: usize, total_size: usize, context: ?*anyopaque) void;
pub const DataWriteCompletedCallbackFn = *const fn (connection: ConnectionId, stream: StreamId, total_bytes_written: usize, context: ?*anyopaque) void;

// -- Common Callback Handler
pub const CallbackHandler = struct {
    callback: ?*const anyopaque,
    context: ?*anyopaque,
};
