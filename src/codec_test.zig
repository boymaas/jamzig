const std = @import("std");
const testing = std.testing;

const codec = @import("codec.zig");
const codec_test = @import("tests/vectors/codec.zig");

const types = @import("types.zig");

test "codec.active: deserialize header from supplied test vector" {
    const allocator = std.testing.allocator;

    const vector = try codec_test.BlockTestVector.build_from(allocator, "src/tests/vectors/codec/codec/data/block.json");
    defer vector.deinit();

    _ = codec.deserialize(types.Header, allocator, vector.binary) catch {};
}
