const std = @import("std");
const tfmt = @import("../types/fmt.zig");

pub fn format(
    chi: anytype,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.writeAll("Chi\n");
    iw.context.indent();

    // Format privileged services
    if (chi.manager) |manager| {
        try iw.print("manager: {d}\n", .{manager});
    } else {
        try iw.writeAll("manager: null\n");
    }

    if (chi.assign) |assign| {
        try iw.print("assign: {d}\n", .{assign});
    } else {
        try iw.writeAll("assign: null\n");
    }

    if (chi.designate) |designate| {
        try iw.print("designate: {d}\n", .{designate});
    } else {
        try iw.writeAll("designate: null\n");
    }

    // Format always_accumulate map
    try iw.writeAll("always_accumulate:\n");
    if (chi.always_accumulate.count() > 0) {
        iw.context.indent();
        var it = chi.always_accumulate.iterator();
        while (it.next()) |entry| {
            try iw.print("service {d}:\n", .{entry.key_ptr.*});
            iw.context.indent();
            try iw.print("gas_limit: {d}\n", .{entry.value_ptr.*});
            iw.context.outdent();
        }
        iw.context.outdent();
    } else {
        iw.context.indent();
        try iw.writeAll("<empty>\n");
        iw.context.outdent();
    }
}

// Test helper to demonstrate formatting
test "Chi format demo" {
    const allocator = std.testing.allocator;
    var chi = @import("../services_priviledged.zig").Chi.init(allocator);
    defer chi.deinit();

    // Set up test data
    chi.setManager(1);
    chi.setAssign(2);
    chi.setDesignate(null);
    try chi.addAlwaysAccumulate(5, 1000);
    try chi.addAlwaysAccumulate(6, 2000);

    // Print formatted output
    std.debug.print("\n=== Chi Format Demo ===\n", .{});
    std.debug.print("{}\n", .{chi});
}
