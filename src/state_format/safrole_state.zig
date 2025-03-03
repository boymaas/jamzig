const std = @import("std");
const Gamma = @import("../safrole_state.zig").Gamma;

const tfmt = @import("../types/fmt.zig");

pub fn format(
    comptime validators_count: u32,
    comptime epoch_length: u32,
    self: *const Gamma(validators_count, epoch_length),
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

const testing = std.testing;
const types = @import("../types.zig");

test "format Gamma state" {
    // Set up test parameters
    const validators_count: u32 = 4;
    const epoch_length: u32 = 3;
    const allocator = testing.allocator;

    // Initialize a Gamma instance with some test data
    var gamma = try Gamma(validators_count, epoch_length).init(allocator);
    defer gamma.deinit(allocator);

    // Set up a test buffer to capture the formatted output
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    std.debug.print("\nGamma State Format Test:\n\n", .{});
    std.debug.print("\n{s}\n", .{gamma});
}
