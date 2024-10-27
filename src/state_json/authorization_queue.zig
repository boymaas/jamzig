const std = @import("std");

const auth_queue = @import("../authorization_queue.zig");
const H = auth_queue.H;
const Phi = auth_queue.Phi;

pub fn jsonStringify(self: *const Phi, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("queue");
    try jw.beginArray();
    for (self.queue) |core_queue| {
        try jw.beginArray();
        for (core_queue.items) |hash| {
            var hex_buf: [H * 2]u8 = undefined;
            const queue = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
            try jw.write(queue);
        }
        try jw.endArray();
    }
    try jw.endArray();
    try jw.endObject();
}
