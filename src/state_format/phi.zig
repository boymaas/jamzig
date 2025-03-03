const std = @import("std");
const tfmt = @import("../types/fmt.zig");

const Phi = @import("../authorizer_queue.zig").Phi;

pub fn format(
    comptime core_count: u32,
    comptime max_authorizations_queue_items: u32,
    self: *const Phi(core_count, max_authorizations_queue_items),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.writeAll("Phi\n");
    iw.context.indent();

    // Count total entries for header
    var total_entries: usize = 0;
    for (self.queue) |core_queue| {
        total_entries += core_queue.items.len;
    }
    try iw.print("total_entries: {d}\n", .{total_entries});

    if (total_entries > 0) {
        try iw.writeAll("queues:\n");
        iw.context.indent();

        try tfmt.formatValue(self.queue, iw, .{});

        iw.context.outdent();
    } else {
        try iw.writeAll("queues: <empty>\n");
    }
}

// Test helper to demonstrate formatting
test "Phi format demo" {
    const core_count: u16 = 4;
    const max_authorizations_queue_items: u16 = 80;
    var phi = try Phi(core_count, max_authorizations_queue_items).init(std.testing.allocator);
    defer phi.deinit();

    // Add test data
    const hash1 = [_]u8{0xA1} ++ [_]u8{0} ** 31;
    const hash2 = [_]u8{0xA2} ++ [_]u8{0} ** 31;
    const hash3 = [_]u8{0xA3} ++ [_]u8{0} ** 31;

    try phi.addAuthorization(1, hash1);
    try phi.addAuthorization(1, hash2);
    try phi.addAuthorization(3, hash3);

    // Print formatted output
    std.debug.print("\n=== Phi Format Demo ===\n", .{});
    std.debug.print("{}\n", .{phi});

    // Print empty state
    var empty_phi = @import("../authorizer_queue.zig").Phi(core_count, max_authorizations_queue_items).init(std.testing.allocator) catch unreachable;
    defer empty_phi.deinit();
    std.debug.print("\n=== Empty Phi Format Demo ===\n", .{});
    std.debug.print("\n{}\n", .{empty_phi});
}
