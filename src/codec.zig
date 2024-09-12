const std = @import("std");

pub fn deserialize(comptime T: type, data: []u8) !T {
    _ = data;
    return error.NotImplemented;
}

// Tests
comptime {
    _ = @import("codec/tests.zig");
    _ = @import("codec/encoder/tests.zig");
    _ = @import("codec/decoder/tests.zig");
    _ = @import("codec/encoder.zig");
}
