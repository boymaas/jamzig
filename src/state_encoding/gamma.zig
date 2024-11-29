const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const jam_params = @import("../jam_params.zig");

pub fn encode(
    comptime params: jam_params.Params,
    gamma: *const state.Gamma(params.validators_count, params.epoch_length),
    writer: anytype,
) !void {
    // Serialize validators array

    std.debug.assert(gamma.k.validators.len == params.validators_count);

    for (gamma.k.validators) |validator| {
        try codec.serialize(types.ValidatorData, params, writer, validator);
    }

    // Serialize VRF root
    try codec.serialize(types.BandersnatchVrfRoot, params, writer, gamma.z);

    // Serialize state-specific fields
    switch (gamma.s) {
        .tickets => |tickets| {
            try codec.serialize(u8, params, writer, 0);

            std.debug.assert(tickets.len == params.epoch_length);

            for (tickets) |ticket| {
                try codec.serialize(types.TicketBody, params, writer, ticket);
            }
        },
        .keys => |keys| {
            try codec.serialize(u8, params, writer, 1);

            std.debug.assert(keys.len == params.epoch_length);

            for (keys) |key| {
                try codec.serialize(types.BandersnatchPublic, params, writer, key);
            }
        },
    }

    std.debug.print("gamma.a: {any}\n", .{gamma.a});

    try codec.serialize([]types.TicketBody, params, writer, gamma.a);
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
