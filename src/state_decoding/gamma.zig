const std = @import("std");
const testing = std.testing;
const state = @import("../state.zig");
const types = @import("../types.zig");
const jam_params = @import("../jam_params.zig");
const codec = @import("../codec.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub const DecoderParams = struct {
    validators_count: u16,
    epoch_length: u32,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .validators_count = params.validators_count,
            .epoch_length = params.epoch_length,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !state.Gamma(params.validators_count, params.epoch_length) {
    try context.push(.{ .component = "gamma" });
    defer context.pop();

    // FIXME: as this allocates we can optimze this away
    var gamma = try state.Gamma(params.validators_count, params.epoch_length).init(allocator);
    errdefer gamma.deinit(allocator);

    // Since validatordata is safe to convert directly we are going to write
    // directly over the memory.
    // See: https://github.com/ziglang/zig/issues/20057
    try context.push(.{ .field = "validators" });
    const vbuffer: []u8 = std.mem.sliceAsBytes(gamma.k.validators);
    reader.readNoEof(vbuffer) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read validators: {s}", .{@errorName(err)});
    };
    context.pop();

    // Decode VRF root
    try context.push(.{ .field = "vrf_root" });
    reader.readNoEof(&gamma.z) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read VRF root: {s}", .{@errorName(err)});
    };
    context.pop();

    // Decode state-specific fields by first checking state type (tickets or keys)
    try context.push(.{ .field = "epoch_state" });
    const state_type = reader.readByte() catch |err| {
        return context.makeError(error.EndOfStream, "failed to read state type: {s}", .{@errorName(err)});
    };
    switch (state_type) {
        0 => { // Tickets state
            const tickets = try allocator.alloc(types.TicketBody, params.epoch_length);
            errdefer allocator.free(tickets);

            const tbuffer: []u8 = std.mem.sliceAsBytes(tickets);
            reader.readNoEof(tbuffer) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read tickets: {s}", .{@errorName(err)});
            };

            gamma.s.deinit(allocator); // Since we will allocate over all the pointers
            gamma.s = .{ .tickets = tickets };
        },
        1 => { // Keys state
            const keys = try allocator.alloc(types.BandersnatchPublic, params.epoch_length);
            errdefer allocator.free(keys);

            const kbuffer: []u8 = std.mem.sliceAsBytes(keys);
            reader.readNoEof(kbuffer) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read keys: {s}", .{@errorName(err)});
            };

            gamma.s.deinit(allocator); // Since we will allocate over all the pointers
            gamma.s = .{ .keys = keys };
        },
        else => return context.makeError(error.InvalidStateType, "invalid state type: {}", .{state_type}),
    }
    context.pop();

    // Decode array length for gamma.a
    try context.push(.{ .field = "tickets_array" });
    const tickets_len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read tickets array length: {s}", .{@errorName(err)});
    };
    const tickets = try allocator.alloc(types.TicketBody, tickets_len);
    errdefer allocator.free(tickets);

    const tbuffer: []u8 = std.mem.sliceAsBytes(tickets);
    reader.readNoEof(tbuffer) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read tickets array: {s}", .{@errorName(err)});
    };
    context.pop();

    gamma.a = tickets;

    return gamma;
}

test "decode gamma - empty state" {
    const allocator = testing.allocator;
    const params = comptime DecoderParams.fromJamParams(jam_params.TINY_PARAMS);

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create minimal buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var writer = buffer.writer();

    // Write empty validator data
    for (0..params.validators_count) |_| {
        try writer.writeAll(&[_]u8{0} ** @sizeOf(types.ValidatorData)); // bandersnatch + ed25519 + bls + metadata
    }

    // Write VRF root
    try writer.writeAll(&[_]u8{0} ** 144); // BLS public key size

    // Write tickets state
    try buffer.writer().writeByte(0); // tickets state type
    for (0..params.epoch_length) |_| {
        try writer.writeAll(&[_]u8{0} ** (32 + 1)); // id + attempt
    }

    // Write empty tickets array
    try buffer.writer().writeByte(0); // length 0

    var fbs = std.io.fixedBufferStream(buffer.items);
    var gamma = try decode(params, allocator, &context, fbs.reader());
    defer gamma.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), gamma.a.len);
}

test "decode gamma - with data" {
    const allocator = testing.allocator;
    const params = comptime DecoderParams.fromJamParams(jam_params.TINY_PARAMS);

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write validator data
    for (0..params.validators_count) |i| {
        try buffer.appendSlice(&[_]u8{@intCast(i)} ** 32); // bandersnatch
        try buffer.appendSlice(&[_]u8{@intCast(i + 1)} ** 32); // ed25519
        try buffer.appendSlice(&[_]u8{@intCast(i + 2)} ** 144); // bls
        try buffer.appendSlice(&[_]u8{@intCast(i + 3)} ** 128); // metadata
    }

    // Write VRF root
    try buffer.appendSlice(&[_]u8{1} ** 144);

    // Write keys state
    try buffer.writer().writeByte(1); // keys state type
    for (0..params.epoch_length) |i| {
        try buffer.appendSlice(&[_]u8{@intCast(i)} ** 32); // bandersnatch public key
    }

    // Write tickets array
    try buffer.writer().writeByte(2); // length 2

    // Write two tickets
    for (0..2) |i| {
        try buffer.appendSlice(&[_]u8{@intCast(i)} ** 32); // id
        try buffer.writer().writeByte(@intCast(i)); // attempt
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    var gamma = try decode(params, allocator, &context, fbs.reader());
    defer gamma.deinit(allocator);

    // Verify validator data
    for (gamma.k.validators, 0..) |validator, i| {
        try testing.expectEqualSlices(u8, &[_]u8{@intCast(i)} ** 32, &validator.bandersnatch);
        try testing.expectEqualSlices(u8, &[_]u8{@intCast(i + 1)} ** 32, &validator.ed25519);
        try testing.expectEqualSlices(u8, &[_]u8{@intCast(i + 2)} ** 144, &validator.bls);
        try testing.expectEqualSlices(u8, &[_]u8{@intCast(i + 3)} ** 128, &validator.metadata);
    }

    // Verify VRF root
    try testing.expectEqualSlices(u8, &[_]u8{1} ** 144, &gamma.z);

    // Verify keys state
    switch (gamma.s) {
        .keys => |keys| {
            for (keys, 0..) |key, i| {
                try testing.expectEqualSlices(u8, &[_]u8{@intCast(i)} ** 32, &key);
            }
        },
        else => return error.UnexpectedStateType,
    }

    // Verify tickets
    try testing.expectEqual(@as(usize, 2), gamma.a.len);
    for (gamma.a, 0..) |ticket, i| {
        try testing.expectEqualSlices(u8, &[_]u8{@intCast(i)} ** 32, &ticket.id);
        try testing.expectEqual(@as(u8, @intCast(i)), ticket.attempt);
    }
}

test "decode gamma - invalid state type" {
    const allocator = testing.allocator;
    const params = comptime DecoderParams.fromJamParams(jam_params.TINY_PARAMS);

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Write minimal valid data until state type
    for (0..params.validators_count) |_| {
        try buffer.appendSlice(&[_]u8{0} ** (32 + 32 + 144 + 128));
    }
    try buffer.appendSlice(&[_]u8{0} ** 144);

    // Write invalid state type
    try buffer.writer().writeByte(2);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const gamma = decode(params, allocator, &context, fbs.reader());
    try testing.expectError(error.InvalidStateType, gamma);
}

test "decode gamma - roundtrip" {
    const allocator = testing.allocator;
    const encoder = @import("../state_encoding/gamma.zig");
    const params = comptime DecoderParams.fromJamParams(jam_params.TINY_PARAMS);

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    // Create original gamma state
    var original = try state.Gamma(params.validators_count, params.epoch_length).init(allocator);
    defer original.deinit(allocator);

    // Set test data
    original.k.validators[0].bandersnatch = [_]u8{1} ** 32;
    original.k.validators[0].ed25519 = [_]u8{2} ** 32;
    original.k.validators[0].bls = [_]u8{3} ** 144;
    original.k.validators[0].metadata = [_]u8{4} ** 128;

    original.z = [_]u8{5} ** 144;

    for (original.s.tickets, 0..) |*ticket, i| {
        ticket.id = [_]u8{@intCast(i + 6)} ** 32;
        ticket.attempt = @intCast(i % 2);
    }

    // Encode
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try encoder.encode(jam_params.TINY_PARAMS, &original, buffer.writer());

    // Decode
    var fbs = std.io.fixedBufferStream(buffer.items);
    var decoded = try decode(params, allocator, &context, fbs.reader());
    defer decoded.deinit(allocator);

    // Verify validator data
    try testing.expectEqualSlices(u8, &original.k.validators[0].bandersnatch, &decoded.k.validators[0].bandersnatch);
    try testing.expectEqualSlices(u8, &original.k.validators[0].ed25519, &decoded.k.validators[0].ed25519);
    try testing.expectEqualSlices(u8, &original.k.validators[0].bls, &decoded.k.validators[0].bls);
    try testing.expectEqualSlices(u8, &original.k.validators[0].metadata, &decoded.k.validators[0].metadata);

    // Verify VRF root
    try testing.expectEqualSlices(u8, &original.z, &decoded.z);

    // Verify tickets
    switch (original.s) {
        .tickets => |orig_tickets| {
            switch (decoded.s) {
                .tickets => |dec_tickets| {
                    try testing.expectEqual(orig_tickets.len, dec_tickets.len);
                    for (orig_tickets, dec_tickets) |orig, dec| {
                        try testing.expectEqualSlices(u8, &orig.id, &dec.id);
                        try testing.expectEqual(orig.attempt, dec.attempt);
                    }
                },
                else => return error.UnexpectedStateType,
            }
        },
        else => return error.UnexpectedStateType,
    }
}
