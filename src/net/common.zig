const std = @import("std");
const network = @import("network");

const shared = @import("jamsnp/shared_types.zig");
pub const ConnectionId = shared.ConnectionId;
pub const StreamId = shared.StreamId;
pub const StreamKind = shared.StreamKind;
pub const StreamHandle = @import("stream_handle.zig").StreamHandle;

const trace = @import("../tracing.zig").scoped(.network);

/// Callback type for command completion
pub fn CommandCallback(T: type) type {
    return *const fn (result: T, context: ?*anyopaque) void;
}

pub fn CommandMetadata(T: type) type {
    return struct {
        callback: ?CommandCallback(T) = null,
        context: ?*anyopaque = null,

        pub fn callWithResult(self: *const CommandMetadata(T), result: T) void {
            if (self.callback) |callback| {
                callback(result, self.context);
            }
        }
    };
}

pub const Event = union(enum) {
    pub fn Result(T: type) type {
        return struct {
            result: T,
            metadata: CommandMetadata(T),

            pub fn invokeCallback(self: *const Result(T)) void {
                self.metadata.callWithResult(self.result);
            }
        };
    }

    // -- Server events
    listening: struct {
        local_endpoint: network.EndPoint,
        result: Result(anyerror!network.EndPoint),
    },

    // -- Connection events
    connected: struct {
        connection_id: ConnectionId,
        endpoint: network.EndPoint,
        metadata: CommandMetadata(anyerror!ConnectionId),
    },

    // -- Client connected from server perspective
    // TODO: merge these connected events into one
    client_connected: struct {
        connection_id: ConnectionId,
        endpoint: network.EndPoint,
        // metadata: CommandMetadata(anyerror!ConnectionId),
    },

    disconnected: struct {
        connection_id: ConnectionId,
    },

    connection_failed: struct {
        endpoint: network.EndPoint,
        connection_id: ConnectionId,
        err: anyerror,
        metadata: CommandMetadata(anyerror!ConnectionId),
    },

    // -- Streams
    stream_created: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        kind: StreamKind,
        metadata: ?CommandMetadata(anyerror!StreamId) = null,
    },
    stream_closed: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
    },

    // -- Data events
    data_received: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        data: []const u8, // owned by original caller
    },
    data_write_completed: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        total_bytes_written: usize,
    },
    message_send: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
    },
    message_received: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        message: []const u8, // Complete message, owned by event
    },
    data_end_of_stream: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        final_data: []const u8, // Data read just before EOS, owned by event
    },
    data_read_error: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        error_code: i32,
    },
    data_write_error: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
        error_code: i32,
    },
    data_read_would_block: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
    },
    data_write_would_block: struct {
        connection_id: ConnectionId,
        stream_id: StreamId,
    },
    @"error": struct {
        message: []const u8,
        details: ?anyerror,
    },

    pub fn invokeCallback(self: Event) void {
        const span = trace.span(.invoke_event_callback);
        defer span.deinit();

        span.debug("Invoking callback for event: {s}", .{@tagName(self)});
        switch (self) {
            .listening => |e| e.result.invokeCallback(),
            else => {
                span.err("Event callback not implemented for this event type", .{});
                @panic("Event callback not implemented for this event type");
            },
        }
    }

    pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
        const span = trace.span(.deinit_event);
        defer span.deinit();

        switch (self.*) {
            .message_received => |e| {
                // Free the message buffer if it was allocated
                if (e.message.len > 0) {
                    alloc.free(e.message);
                }
            },
            .data_received => |data| {
                // Free the data buffer if it was allocated
                alloc.free(data.data);
            },
            .data_end_of_stream => |data| {
                // Free the final_data buffer if it was allocated
                alloc.free(data.final_data);
            },
            else => {},
        }
        self.* = undefined;
    }
};

//
// pub const Event = union(enum) {
//     connected: struct {
//         connection_id: ConnectionId,
//         endpoint: network.EndPoint,
//         metadata: CommandMetadata(anyerror!ConnectionId),
//     },
//     connection_failed: struct {
//         endpoint: network.EndPoint,
//         connection_id: ConnectionId,
//         err: anyerror,
//         metadata: CommandMetadata(anyerror!ConnectionId),
//     },
//     disconnected: struct {
//         connection_id: ConnectionId,
//     },
//     stream_created: struct { // Includes streams created by peer? Server only has stream_created_by_client
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         metadata: CommandMetadata(anyerror!StreamId),
//     },
//     stream_closed: struct {
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//     },
//     data_received: struct {
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         data: []const u8, // Owned by event, must be freed by consumer
//     },
//     data_end_of_stream: struct {
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         final_data: []const u8, // Data read just before EOS, owned by event
//     },
//     data_write_completed: struct { // Signifies buffer sent by SendData is done
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         bytes_written: usize,
//     },
//     message_send: struct {
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//     },
//     message_received: struct {
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         message: []const u8, // Complete message, owned by event
//     },
//
//     // -- Error/Status Events --
//     data_read_error: struct {
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         err: anyerror,
//         raw_error_code: i32,
//     },
//     data_write_error: struct { // Error sending buffer from SendData
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//         err: anyerror,
//         raw_error_code: i32,
//     },
//     data_read_would_block: struct { // Info: reading stopped, call wantRead(true) again
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//     },
//     data_write_would_block: struct { // Info: writing stopped, call wantWrite(true) again if more data
//         connection_id: ConnectionId,
//         stream_id: StreamId,
//     },
//     @"error": struct { // General error event
//         message: []const u8, // Can be literal or allocated (check details)
//         details: ?anyerror,
//     },
//
//     pub fn deinit(self: Event, alloc: std.mem.Allocator) void {
//         switch (self) {
//             .data_received => |data| {
//                 // Free the data buffer if it was allocated
//                 alloc.free(data.data);
//             },
//             .message_received => |msg| {
//                 // Free the message buffer if it was allocated
//                 alloc.free(msg.message);
//             },
//             .data_end_of_stream => |data| {
//                 // Free the final_data buffer if it was allocated
//                 alloc.free(data.final_data);
//             },
//             else => |_| {},
//         }
//     }
// };
