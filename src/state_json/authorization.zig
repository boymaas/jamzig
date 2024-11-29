const std = @import("std");
const Alpha = @import("../authorization.zig").Alpha;

pub fn jsonStringify(comptime core_count: u16, self: *const Alpha(core_count), jw: anytype) !void {
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

    try jw.objectField("queues");
    try jw.beginArray();
    for (self.queues) |queue| {
        try jw.beginArray();
        for (queue.constSlice()) |auth| {
            try jw.write(std.fmt.fmtSliceHexLower(&auth));
        }
        try jw.endArray();
    }
    try jw.endArray();

    try jw.endObject();
}
