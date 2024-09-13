const std = @import("std");
const testing = std.testing;

const codec = @import("codec.zig");
const codec_test = @import("tests/vectors/codec.zig");

const convert = @import("tests/convert/codec.zig");

const types = @import("types.zig");

/// The Tiny PARAMS as they are defined in the ASN
const TINY_PARAMS = types.CodecParams{
    .validators = 6,
    .epoch_length = 12,
    .cores_count = 2,
    .validators_super_majority = 5,
    .avail_bitfield_bytes = 1,
};

test "codec: decode header-0" {
    const allocator = std.testing.allocator;

    const vector = try codec_test.CodecTestVector(codec_test.types.Header).build_from(allocator, "src/tests/vectors/codec/codec/data/header_0.json");
    defer vector.deinit();

    var header = try codec.deserialize(types.Header, TINY_PARAMS, allocator, vector.binary);
    defer header.deinit();

    std.debug.print("header: {any}\n", .{header.value});

    // try std.json.stringify(header.value, .{ .whitespace = .indent_2 }, std.io.getStdErr().writer());
    std.debug.print("\n", .{});
}

test "codec.active: decode header-1" {
    const allocator = std.testing.allocator;

    const vector = try codec_test.CodecTestVector(codec_test.types.Header).build_from(allocator, "src/tests/vectors/codec/codec/data/header_1.json");
    defer vector.deinit();

    const header = try codec.deserialize(types.Header, TINY_PARAMS, allocator, vector.binary);
    defer header.deinit();

    std.debug.print("header: {any}\n", .{header.value});

    // try std.json.stringify(header.value, .{ .whitespace = .indent_2 }, std.io.getStdErr().writer());
    std.debug.print("\n", .{});

    // const expected = try convert.headerFromTestVector(allocator, &vector.expected.value);
    const expected = try convert.convertHeader(allocator, vector.expected.value);
    defer convert.generic.free(allocator, expected);

    std.debug.print("expected: {any}\n", .{expected});

    try std.testing.expectEqualDeep(expected, header.value);
}
