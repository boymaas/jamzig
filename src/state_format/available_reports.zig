const std = @import("std");
const Theta = @import("../available_reports.zig").Theta;

const tfmt = @import("../types/fmt.zig");

pub fn format(
    comptime epoch_size: usize,
    self: *const Theta(epoch_size),
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.writeAll("Theta: (empty are omitted)\n");
    iw.context.indent();
    for (self.entries, 0..) |slot_entries, i| {
        if (slot_entries.items.len > 0) {
            try iw.print("Slot {d}: ", .{i});
            iw.context.indent();
            try tfmt.formatValue(slot_entries, iw);
            iw.context.outdent();
        }
    }
    iw.context.outdent();
}

test "Theta - format" {
    const allocator = std.heap.page_allocator;

    // Initialize a test Theta instance
    var theta = Theta(4).init(allocator);
    defer theta.deinit();

    const Entry = @import("../available_reports.zig").Entry;
    const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;

    // Create a report with some test data
    var entry1 = Entry{
        .work_report = createEmptyWorkReport([_]u8{1} ** 32),
        .dependencies = .{},
    };
    try entry1.dependencies.put(allocator, [_]u8{2} ** 32, {});
    try entry1.dependencies.put(allocator, [_]u8{3} ** 32, {});

    var entry2 = Entry{
        .work_report = createEmptyWorkReport([_]u8{4} ** 32),
        .dependencies = .{},
    };
    try entry2.dependencies.put(allocator, [_]u8{5} ** 32, {});

    // Add entries to different slots
    try theta.addEntryToTimeSlot(1, entry1);
    try theta.addEntryToTimeSlot(1, entry2);

    // Format to string
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    std.debug.print("\n{s}\n", .{theta});
}
