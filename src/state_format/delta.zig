const std = @import("std");
const Delta = @import("../services.zig").Delta;

pub fn format(
    self: *const Delta,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Delta{\n");
    try writer.writeAll("  Accounts:\n");
    
    var it = self.accounts.iterator();
    while (it.next()) |entry| {
        const account = entry.value_ptr;
        try writer.print("    {d}: {{\n", .{entry.key_ptr.*});
        try writer.print("      balance: {d}\n", .{account.balance});
        try writer.print("      min_gas_accumulate: {d}\n", .{account.min_gas_accumulate});
        try writer.print("      min_gas_on_transfer: {d}\n", .{account.min_gas_on_transfer});
        try writer.print("      storage_count: {d}\n", .{account.storage.count()});
        try writer.print("      preimages_count: {d}\n", .{account.preimages.count()});
        try writer.print("      preimage_lookups_count: {d}\n", .{account.preimage_lookups.count()});
        try writer.writeAll("    }\n");
    }

    try writer.writeAll("}");
}
