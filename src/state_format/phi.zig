const std = @import("std");
const tfmt = @import("../types/fmt.zig");

const Phi = @import("../authorizer_queue.zig").Phi;

pub fn format(
    comptime core_count: u32,
    comptime authorization_queue_length: u32,
    self: *const Phi(core_count, authorization_queue_length),
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

    // Count non-empty entries
    var non_empty_count: usize = 0;
    for (0..core_count) |core| {
        for (0..authorization_queue_length) |index| {
            if (!self.isEmptySlot(core, index)) {
                non_empty_count += 1;
            }
        }
    }
    
    try iw.print("cores: {d}\n", .{core_count});
    try iw.print("queue_length: {d}\n", .{authorization_queue_length});
    try iw.print("non_empty_slots: {d}\n", .{non_empty_count});

    if (non_empty_count > 0) {
        try iw.writeAll("authorizations:\n");
        iw.context.indent();

        for (0..core_count) |core| {
            var has_entries = false;
            for (0..authorization_queue_length) |index| {
                if (!self.isEmptySlot(core, index)) {
                    if (!has_entries) {
                        try iw.print("core {d}:\n", .{core});
                        iw.context.indent();
                        has_entries = true;
                    }
                    const hash = self.getAuthorization(core, index);
                    try iw.print("[{d}]: {s}\n", .{ index, std.fmt.fmtSliceHexLower(&hash) });
                }
            }
            if (has_entries) {
                iw.context.outdent();
            }
        }

        iw.context.outdent();
    } else {
        try iw.writeAll("authorizations: <all empty>\n");
    }
}

// Test helper to demonstrate formatting
test "Phi format demo" {
    const core_count: u16 = 4;
    const authorization_queue_length: u16 = 80;
    var phi = try Phi(core_count, authorization_queue_length).init(std.testing.allocator);
    defer phi.deinit();

    // Add test data
    const hash1 = [_]u8{0xA1} ++ [_]u8{0} ** 31;
    const hash2 = [_]u8{0xA2} ++ [_]u8{0} ** 31;
    const hash3 = [_]u8{0xA3} ++ [_]u8{0} ** 31;

    try phi.setAuthorization(1, 0, hash1);
    try phi.setAuthorization(1, 1, hash2);
    try phi.setAuthorization(3, 5, hash3);

    // Print formatted output
    std.debug.print("\n=== Phi Format Demo ===\n", .{});
    std.debug.print("{}\n", .{phi});

    // Print empty state
    var empty_phi = @import("../authorizer_queue.zig").Phi(core_count, authorization_queue_length).init(std.testing.allocator) catch unreachable;
    defer empty_phi.deinit();
    std.debug.print("\n=== Empty Phi Format Demo ===\n", .{});
    std.debug.print("\n{}\n", .{empty_phi});
}
