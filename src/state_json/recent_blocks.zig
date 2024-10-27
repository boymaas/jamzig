const std = @import("std");

const Beta = @import("../recent_blocks.zig").RecentHistory;

pub fn jsonStringify(self: *const Beta, jw: anytype) !void {
    try jw.beginObject();
    try jw.objectField("max_blocks");
    try jw.write(self.max_blocks);
    try jw.objectField("blocks");
    try jw.beginArray();
    for (self.blocks.items) |block| {
        try jw.beginObject();
        try jw.objectField("header_hash");
        try jw.write(std.fmt.fmtSliceHexLower(&block.header_hash));
        try jw.objectField("state_root");
        try jw.write(std.fmt.fmtSliceHexLower(&block.state_root));
        try jw.objectField("beefy_mmr");
        try jw.beginArray();
        for (block.beefy_mmr) |maybe_hash| {
            if (maybe_hash) |hash| {
                try jw.write(std.fmt.fmtSliceHexLower(&hash));
            } else {
                try jw.write(null);
            }
        }
        try jw.endArray();
        try jw.objectField("work_reports");
        try jw.beginArray();
        for (block.work_reports) |hash| {
            try jw.write(std.fmt.fmtSliceHexLower(&hash));
        }
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}
