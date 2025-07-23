const std = @import("std");

const auth_queue = @import("../authorizer_queue.zig");
const H = auth_queue.H; // TODO: remove
const Phi = auth_queue.Phi;

pub fn jsonStringify(self: anytype, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("queue_data");
    try jw.beginArray();
    
    // Write all authorization hashes in the flat array
    for (self.queue_data) |hash| {
        var hex_buf: [H * 2]u8 = undefined;
        const hex_str = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
        try jw.write(hex_str);
    }
    
    try jw.endArray();
    try jw.endObject();
}
