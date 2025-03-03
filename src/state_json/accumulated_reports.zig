const std = @import("std");
const Xi = @import("../accumulated_reports.zig").Xi;

pub fn jsonStringify(comptime epoch_size: usize, self: *const Xi(epoch_size), jw: anytype) !void {
    try jw.beginArray();
    for (self.entries) |slot_entries| {
        try jw.beginObject();
        var iterator = slot_entries.iterator();
        while (iterator.next()) |entry| {
            var buffer: [128]u8 = undefined;
            const hexStr = std.fmt.bufPrint(&buffer, "0x{s}", .{std.fmt.fmtSliceHexLower(&entry.key_ptr.*)}) catch unreachable;
            try jw.objectField(hexStr);
        }
        try jw.endObject();
    }
    try jw.endArray();
}
