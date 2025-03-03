const std = @import("std");
const Psi = @import("../disputes.zig").Psi;

const tfmt = @import("../types/fmt.zig");

pub fn format(
    self: *const Psi,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    const iw = indented_writer.writer();

    try tfmt.formatValue(self.*, iw, .{});
}

test "format Psi state" {
    const allocator = std.testing.allocator;

    // Create a sample Psi state
    var psi = Psi.init(allocator);
    defer psi.deinit();

    // Add some sample data to each set
    try psi.good_set.put([_]u8{1} ** 32, {});
    try psi.bad_set.put([_]u8{2} ** 32, {});
    try psi.wonky_set.put([_]u8{3} ** 32, {});
    try psi.punish_set.put([_]u8{4} ** 32, {});
    try psi.punish_set.put([_]u8{5} ** 32, {});

    // Print formatted output to stdout
    std.debug.print("\n{s}\n", .{psi});
}
