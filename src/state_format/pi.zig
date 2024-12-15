const std = @import("std");
const tfmt = @import("../types/fmt.zig");
const Pi = @import("../validator_stats.zig").Pi;

pub fn formatPi(
    self: *const Pi,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    const iw = indented_writer.writer();

    try tfmt.formatValue(self.*, iw);
}

test "format Pi state" {
    const allocator = std.testing.allocator;

    // Create a sample Pi state
    var pi = try Pi.init(allocator, 1);
    defer pi.deinit();

    // Add some sample data
    try pi.current_epoch_stats.append(.{
        .blocks_produced = 42,
        .tickets_introduced = 15,
        .preimages_introduced = 7,
        .octets_across_preimages = 1024,
        .reports_guaranteed = 30,
        .availability_assurances = 25,
    });
    try pi.previous_epoch_stats.append(.{
        .blocks_produced = 42,
        .tickets_introduced = 15,
        .preimages_introduced = 7,
        .octets_across_preimages = 1024,
        .reports_guaranteed = 30,
        .availability_assurances = 25,
    });
    pi.validator_count = 1;

    // Print formatted output to stdout
    std.debug.print("\nPi State Format Test:\n", .{});
    std.debug.print("\n{s}\n", .{pi});
}
