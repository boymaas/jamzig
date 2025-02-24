const std = @import("std");
const Alpha = @import("../authorization.zig").Alpha;

pub fn jsonStringify(comptime core_count: u16, comptime max_pool_items: u8, self: *const Alpha(core_count, max_pool_items), jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("pools");
    try jw.beginArray();
    for (self.pools) |pool| {
        try jw.beginArray();
        for (pool.constSlice()) |auth| {
            try jw.write(std.fmt.fmtSliceHexLower(&auth));
        }
        try jw.endArray();
    }
    try jw.endArray();

    try jw.endObject();
}
