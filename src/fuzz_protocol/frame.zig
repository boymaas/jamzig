const std = @import("std");
const net = std.net;
const constants = @import("constants.zig");

/// Read a length-prefixed frame from the stream
pub fn readFrame(allocator: std.mem.Allocator, stream: net.Stream) ![]u8 {
    var len_bytes: [4]u8 = undefined;
    const bytes_read = try stream.readAll(&len_bytes);
    if (bytes_read != 4) return error.UnexpectedEndOfStream;

    const message_len = std.mem.readInt(u32, &len_bytes, .little);
    if (message_len > constants.MAX_MESSAGE_SIZE) return error.MessageTooLarge;

    const frame_data = try allocator.alloc(u8, message_len);
    errdefer allocator.free(frame_data);

    const content_read = try stream.readAll(frame_data);
    if (content_read != message_len) return error.UnexpectedEndOfStream;

    return frame_data;
}

/// Write a frame to the stream with length prefix
pub fn writeFrame(stream: net.Stream, data: []const u8) !void {
    if (data.len > constants.MAX_MESSAGE_SIZE) return error.MessageTooLarge;

    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .little);
    _ = try stream.writeAll(&len_bytes);

    _ = try stream.writeAll(data);
}

