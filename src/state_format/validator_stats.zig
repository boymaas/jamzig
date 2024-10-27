const std = @import("std");
const Pi = @import("../validator_stats.zig").Pi;
const ValidatorStats = @import("../validator_stats.zig").ValidatorStats;

pub fn formatPi(
    self: *const Pi,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.writeAll("Pi{\n");

    try writer.writeAll("  Current Epoch Stats:\n");
    for (self.current_epoch_stats.items, 0..) |stats, i| {
        try writer.print("    Validator {d}:\n", .{i});
        try formatValidatorStats(&stats, fmt, options, writer);
    }

    try writer.writeAll("\n  Previous Epoch Stats:\n");
    for (self.previous_epoch_stats.items, 0..) |stats, i| {
        try writer.print("    Validator {d}:\n", .{i});
        try formatValidatorStats(&stats, fmt, options, writer);
    }

    try writer.writeAll("}");
}

pub fn formatValidatorStats(
    self: *const ValidatorStats,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.print("      blocks_produced: {d}\n", .{self.blocks_produced});
    try writer.print("      tickets_introduced: {d}\n", .{self.tickets_introduced});
    try writer.print("      preimages_introduced: {d}\n", .{self.preimages_introduced});
    try writer.print("      octets_across_preimages: {d}\n", .{self.octets_across_preimages});
    try writer.print("      reports_guaranteed: {d}\n", .{self.reports_guaranteed});
    try writer.print("      availability_assurances: {d}\n", .{self.availability_assurances});
}
