const std = @import("std");
const tfmt = @import("../types/fmt.zig");
const Delta = @import("../services.zig").Delta;

pub fn format(
    self: *const Delta,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
    var iw = indented_writer.writer();

    try iw.writeAll("Delta\n");
    iw.context.indent();

    try tfmt.formatValue(self.*, iw);
    //
    // const total_accounts = self.accounts.count();
    // try iw.print("total_accounts: {d}\n", .{total_accounts});
    //
    // if (total_accounts > 0) {
    //     try iw.writeAll("accounts:\n");
    //     iw.context.indent();
    //     var it = self.accounts.iterator();
    //     while (it.next()) |entry| {
    //         try iw.print("service {d}:\n", .{entry.key_ptr.*});
    //         iw.context.indent();
    //         try tfmt.formatValue(entry.value_ptr.*, iw);
    //         try iw.writeAll("\n");
    //         iw.context.outdent();
    //     }
    //     iw.context.outdent();
    // } else {
    //     try iw.writeAll("accounts: <empty>\n");
    // }
}

// Test helper to demonstrate formatting
test "Delta format demo" {
    const allocator = std.testing.allocator;
    var delta = @import("../services.zig").Delta.init(allocator);
    defer delta.deinit();

    // Create a test account
    var account1 = @import("../services.zig").ServiceAccount.init(allocator);
    account1.balance = 1000;
    account1.min_gas_accumulate = 100;
    account1.min_gas_on_transfer = 50;
    account1.code_hash = [_]u8{0xA1} ++ [_]u8{0} ** 31;

    // Add some storage
    try account1.writeStorage([_]u8{0xB1} ++ [_]u8{0} ** 31, "test_value");

    // Add some preimages
    try account1.addPreimage([_]u8{0xC1} ++ [_]u8{0} ** 31, "test_preimage");
    try account1.integratePreimageLookup([_]u8{0xC1} ++ [_]u8{0} ** 31, 12, 42);

    // Add account to delta
    try delta.putAccount(1, account1);

    // Create another account with different values
    var account2 = @import("../services.zig").ServiceAccount.init(allocator);
    account2.balance = 2000;
    account2.min_gas_accumulate = 200;
    account2.min_gas_on_transfer = 100;
    account2.code_hash = [_]u8{0xA2} ++ [_]u8{0} ** 31;
    try delta.putAccount(2, account2);

    // Print formatted output
    std.debug.print("\n=== Delta Format Demo ===\n", .{});
    std.debug.print("{}\n", .{delta});
}
