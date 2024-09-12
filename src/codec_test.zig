const std = @import("std");
const testing = std.testing;

const codec = @import("codec.zig");
const codec_test = @import("tests/vectors/codec.zig");

const types = @import("types.zig");

test "codec.active: deserialize header from supplied test vector" {
    const allocator = std.testing.allocator;

    const vector = try codec_test.BlockTestVector.build_from(allocator, "src/tests/vectors/codec/codec/data/block.json");
    defer vector.deinit();

    var header = try codec.deserialize(types.Header, allocator, vector.binary);
    defer header.deinit();

    std.debug.print("header: {any}\n", .{header.value});

    try std.json.stringify(header.value, .{ .whitespace = .indent_2 }, std.io.getStdErr().writer());
    std.debug.print("\n", .{});
}
