const std = @import("std");
const tfmt = @import("../types/fmt.zig");

const Alpha = @import("../authorization.zig").Alpha;

pub fn format(
    comptime core_count: u32,
    self: Alpha(core_count),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.writeAll("Alpha\n");
    iw.context.indent();

    // Format pools
    try iw.writeAll("pools: (empty are omitted)\n");
    iw.context.indent();
    var has_pools = false;
    for (self.pools, 0..) |pool, i| {
        if (pool.len > 0) {
            has_pools = true;
            try iw.print("core {d}: ", .{i});
            iw.context.indent();
            try tfmt.formatValue(pool, iw);
            iw.context.outdent();
        }
    }
    if (!has_pools) {
        try iw.writeAll("<empty>\n");
    }
    iw.context.outdent();
}

// Test helper to demonstrate formatting
test "Alpha format demo" {
    const core_count = 4;
    var alpha = Alpha(core_count).init();

    // Add some test data
    const auth1 = [_]u8{0xA1} ++ [_]u8{0} ** 31;
    const auth2 = [_]u8{0xA2} ++ [_]u8{0} ** 31;
    const auth3 = [_]u8{0xA3} ++ [_]u8{0} ** 31;

    // Add to pools
    try alpha.pools[1].append(auth1);
    try alpha.pools[1].append(auth2);
    try alpha.pools[3].append(auth3);

    // Print formatted output
    std.debug.print("\n{}\n", .{alpha});
}
