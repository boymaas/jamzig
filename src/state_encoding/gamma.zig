const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const serialize = @import("../codec.zig").serialize;

const EncodeSchema = struct {
    validators: []types.ValidatorData,
    z: types.BandersnatchVrfRoot,
    x: u8,
    s: types.GammaS,
    a: types.GammaA,
};

pub fn encode(gamma: *const state.Gamma, writer: anytype) !void {
    const x: u8 = switch (gamma.s) {
        .keys => 1,
        .tickets => 0,
    };
    const data = EncodeSchema{
        .validators = gamma.k.validators, // TODO this should be a count validators array
        .z = gamma.z,
        .x = x,
        .s = gamma.s,
        .a = gamma.a,
    };

    try serialize(EncodeSchema, .{}, writer, data);
}

//  _____         _   _
// |_   _|__  ___| |_(_)_ __   __ _
//   | |/ _ \/ __| __| | '_ \ / _` |
//   | |  __/\__ \ |_| | | | | (_| |
//   |_|\___||___/\__|_|_| |_|\__, |
//                            |___/

test "encode" {
    const testing = std.testing;
    const allocator = std.testing.allocator;

    // Create a sample Gamma instance
    var gamma = try state.Gamma.init(allocator, 6);
    defer gamma.deinit(allocator);

    // Create a buffer to store the encoded data
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Encode the Gamma instance
    try encode(&gamma, buffer.writer());

    // Verify the encoded output
    // Here, we're just checking if the buffer is not empty.
    try testing.expect(buffer.items.len > 0);

    // TODO: add more detailed tests
}
