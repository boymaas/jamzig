const std = @import("std");

pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("manager");
    if (self.manager) |manager| {
        try jw.write(manager);
    } else {
        try jw.write(null);
    }

    try jw.objectField("assign");
    if (self.assign) |assign| {
        try jw.write(assign);
    } else {
        try jw.write(null);
    }

    try jw.objectField("designate");
    if (self.designate) |designate| {
        try jw.write(designate);
    } else {
        try jw.write(null);
    }

    try jw.objectField("always_accumulate");
    try jw.beginObject();
    var it = self.always_accumulate.iterator();
    while (it.next()) |entry| {
        const key = try std.fmt.allocPrint(self.allocator, "{}", .{entry.key_ptr.*});
        defer self.allocator.free(key);
        try jw.objectField(key);
        try jw.write(entry.value_ptr.*);
    }
    try jw.endObject();

    try jw.endObject();
}
