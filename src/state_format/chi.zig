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
    try tfmt.formatValue(chi.*, iw, .{});
    iw.context.outdent();
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
    std.debug.print("\n{}\n", .{chi});
}
