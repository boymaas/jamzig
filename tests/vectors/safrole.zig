const std = @import("std");
const safrole = @import("./libs/safrole.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_vector = try safrole.TestVector.build_from(allocator, "tests/vectors/jam/safrole/tiny/publish-tickets-no-mark-1.json");
    defer test_vector.deinit();

    // std.debug.print("Test vector: {}\n", .{test_vector.value.input.entropy});
    // std.debug.print("Test vector: {any}\n", .{test_vector.value.input.extrinsic[1]});
    // std.debug.print("Test vector: {}\n", .{test_vector.value});

    // stringify the JSON string
    const stdout = std.io.getStdOut().writer();
    try std.json.stringify(test_vector.value, .{ .whitespace = .indent_2 }, stdout);
}
