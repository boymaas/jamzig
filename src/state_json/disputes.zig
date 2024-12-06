const std = @import("std");
const Psi = @import("../disputes.zig").Psi;

pub fn jsonStringify(self: *const Psi, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("good_set");
    try jw.beginArray();
    for (self.good_set.keys()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key));
    }
    try jw.endArray();

    try jw.objectField("bad_set");
    try jw.beginArray();
    for (self.bad_set.keys()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key));
    }
    try jw.endArray();

    try jw.objectField("wonky_set");
    try jw.beginArray();
    for (self.wonky_set.keys()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key));
    }
    try jw.endArray();

    try jw.objectField("punish_set");
    try jw.beginArray();
    for (self.punish_set.keys()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key));
    }
    try jw.endArray();

    try jw.endObject();
}
