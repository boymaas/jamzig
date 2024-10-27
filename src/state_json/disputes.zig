const std = @import("std");
const Psi = @import("../disputes.zig").Psi;

pub fn jsonStringify(self: *const Psi, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("good_set");
    try jw.beginArray();
    var good_it = self.good_set.keyIterator();
    while (good_it.next()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key.*));
    }
    try jw.endArray();

    try jw.objectField("bad_set");
    try jw.beginArray();
    var bad_it = self.bad_set.keyIterator();
    while (bad_it.next()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key.*));
    }
    try jw.endArray();

    try jw.objectField("wonky_set");
    try jw.beginArray();
    var wonky_it = self.wonky_set.keyIterator();
    while (wonky_it.next()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key.*));
    }
    try jw.endArray();

    try jw.objectField("punish_set");
    try jw.beginArray();
    var punish_it = self.punish_set.keyIterator();
    while (punish_it.next()) |key| {
        try jw.write(std.fmt.fmtSliceHexLower(&key.*));
    }
    try jw.endArray();

    try jw.endObject();
}
