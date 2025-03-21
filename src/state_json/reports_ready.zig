const std = @import("std");
const Theta = @import("../reports_ready.zig").Theta;

pub fn jsonStringify(comptime epoch_size: usize, self: *const Theta(epoch_size), jw: anytype) !void {
    try jw.beginArray();
    for (self.entries) |slot_entries| {
        for (slot_entries.items) |entry| {
            try jw.beginObject();
            try jw.objectField("work_report");
            try jw.write(entry.work_report);
            try jw.objectField("dependencies");
            try jw.beginArray();
            var iterator = entry.dependencies.iterator();
            while (iterator.next()) |_| {
                // TODO:  fix this
                // try jw.writeString(std.fmt.fmtSliceHexLower(key));
            }
            try jw.endArray();
            try jw.endObject();
        }
    }
    try jw.endArray();
}
