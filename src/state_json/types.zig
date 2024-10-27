const std = @import("std");
const ValidatorData = @import("../types.zig").ValidatorData;

pub fn jsonStringify(self: *const ValidatorData, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("bandersnatch");
    try jw.write(std.fmt.fmtSliceHexLower(&self.bandersnatch));

    try jw.objectField("ed25519");
    try jw.write(std.fmt.fmtSliceHexLower(&self.ed25519));

    try jw.objectField("bls");
    try jw.write(std.fmt.fmtSliceHexLower(&self.bls));

    try jw.objectField("metadata");
    try jw.write(std.fmt.fmtSliceHexLower(&self.metadata));

    try jw.endObject();
}
