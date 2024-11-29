const std = @import("std");
const Gamma = @import("../safrole_state.zig").Gamma;

pub fn jsonStringify(
    comptime validators_count: u32,
    comptime epoch_length: u32,
    self: *const Gamma(validators_count, epoch_length),
    jw: anytype,
) !void {
    try jw.beginObject();

    try jw.objectField("k");
    try jw.write(self.k);

    try jw.objectField("z");
    try jw.write(self.z);

    try jw.objectField("s");
    try jw.beginObject();
    switch (self.s) {
        .tickets => |tickets| {
            try jw.objectField("tickets");
            try jw.write(tickets);
        },
        .keys => |keys| {
            try jw.objectField("keys");
            try jw.write(keys);
        },
    }
    try jw.endObject();

    try jw.objectField("a");
    try jw.write(self.a);

    try jw.endObject();
}
