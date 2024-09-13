const std = @import("std");
const testing = std.testing;

const codec = @import("codec.zig");
const codec_test = @import("tests/vectors/codec.zig");

const types = @import("types.zig");

test "codec.active: decode header" {
    const allocator = std.testing.allocator;

    const vector = try codec_test.CodecTestVector(codec_test.types.Header).build_from(allocator, "src/tests/vectors/codec/codec/data/header_0.json");
    defer vector.deinit();

    // We need to specify these variables at runtime, and at deserialization
    // check if they are present.
    //
    // validators-count INTEGER ::= 6
    // epoch-length INTEGER ::= 12
    // cores-count INTEGER ::= 2
    //
    // -- (validators-count * 2/3 + 1)
    // validators-super-majority INTEGER ::= 5
    // -- (cores-count + 7) / 8
    // avail-bitfield-bytes INTEGER ::= 1

    var header = try codec.deserialize(types.Header, allocator, vector.binary);
    defer header.deinit();

    std.debug.print("header: {any}\n", .{header.value});

    // try std.json.stringify(header.value, .{ .whitespace = .indent_2 }, std.io.getStdErr().writer());
    std.debug.print("\n", .{});
}
