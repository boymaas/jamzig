const std = @import("std");
const uuid = @import("uuid");
const network = @import("network");

const trace = @import("../../tracing.zig").scoped(.network);

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

// -- Callback Invocation

pub const CallbackHandlers = [@typeInfo(EventType).@"enum".fields.len]CallbackHandler;
pub const CALLBACK_HANDLERS_EMPTY = [_]CallbackHandler{.{ .callback = null, .context = null }} ** @typeInfo(EventType).@"enum".fields.len;

// Argument Union for invokeCallback (using shared types)
const EventArgs = union(EventType) {
    ClientConnected: struct { connection: ConnectionId, endpoint: network.EndPoint },
    ConnectionEstablished: struct { connection: ConnectionId, endpoint: network.EndPoint },
    ConnectionFailed: struct { endpoint: network.EndPoint, err: anyerror },
    ConnectionClosed: struct { connection: ConnectionId },
    StreamCreated: struct { connection: ConnectionId, stream: StreamId },
    StreamClosed: struct { connection: ConnectionId, stream: StreamId },
    DataReceived: struct { connection: ConnectionId, stream: StreamId, data: []const u8 },
    DataEndOfStream: struct { connection: ConnectionId, stream: StreamId, data_read: []const u8 },
    DataReadError: struct { connection: ConnectionId, stream: StreamId, error_code: i32 },
    DataWouldBlock: struct { connection: ConnectionId, stream: StreamId },
    DataWriteProgress: struct { connection: ConnectionId, stream: StreamId, bytes_written: usize, total_size: usize },
    DataWriteCompleted: struct { connection: ConnectionId, stream: StreamId, total_bytes_written: usize },
    DataWriteError: struct { connection: ConnectionId, stream: StreamId, error_code: i32 },
};

pub fn invokeCallback(callback_handlers: *const CallbackHandlers, event_tag: EventType, args: EventArgs) void {
    const span = trace.span(.invoke_callback);
    defer span.deinit();
    std.debug.assert(event_tag == @as(EventType, @enumFromInt(@intFromEnum(args))));

    const handler = &callback_handlers[@intFromEnum(event_tag)];
    if (handler.callback) |callback_ptr| {
        span.debug("Invoking callback for event {s}", .{@tagName(event_tag)});
        switch (args) {
            .ClientConnected => |ev_args| {
                const callback: ClientConnectedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.endpoint, handler.context);
            },
            .ConnectionEstablished => |ev_args| {
                const callback: ClientConnectedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.endpoint, handler.context);
            },
            .ConnectionClosed => |ev_args| {
                const callback: ConnectionClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, handler.context);
            },
            .StreamCreated => |ev_args| {
                const callback: StreamCreatedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, handler.context);
            },
            .StreamClosed => |ev_args| {
                const callback: StreamClosedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, handler.context);
            },
            .DataReceived => |ev_args| {
                const callback: DataReceivedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, ev_args.data, handler.context);
            },
            .DataWriteCompleted => |ev_args| {
                const callback: DataWriteCompletedCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, ev_args.total_bytes_written, handler.context);
            },
            .DataReadError => |ev_args| {
                const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, ev_args.error_code, handler.context);
            },
            .DataWriteError => |ev_args| {
                const callback: DataErrorCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, ev_args.error_code, handler.context);
            },
            .DataWouldBlock => |ev_args| {
                const callback: DataWouldBlockCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, handler.context);
            },
            .DataWriteProgress => |ev_args| {
                const callback: DataWriteProgressCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, ev_args.bytes_written, ev_args.total_size, handler.context);
            },
            .DataEndOfStream => |ev_args| {
                const callback: DataEndOfStreamCallbackFn = @ptrCast(@alignCast(callback_ptr));
                callback(ev_args.connection, ev_args.stream, ev_args.data_read, handler.context);
            },
            .ConnectionFailed => |ev_args| {
                // This seems to be server-specific, not used in client callbacks
                span.warn("Unhandled ConnectionFailed event for endpoint: {}", .{ev_args.endpoint});
            },
        }
    } else {
        span.trace("No server callback registered for event type {s}", .{@tagName(event_tag)});
    }
}
