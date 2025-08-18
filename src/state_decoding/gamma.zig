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

    // Directly construct gamma without unnecessary allocations
    var gamma = state.Gamma(params.validators_count, params.epoch_length){
        .k = .{
            .validators = try allocator.alloc(types.ValidatorData, params.validators_count),
        },
        .z = undefined, // Will be filled
        .s = undefined, // Will be set on discriminator
        .a = undefined, // Will be allocated based on size
    };
    errdefer {
        allocator.free(gamma.k.validators);
        // s and a are cleaned up in their own errdefer blocks when allocated
    }

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
    // Graypaper C.1.4: Read discriminator as natural (variable-length integer)
    const state_type = codec.readInteger(reader) catch |err| {
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

            gamma.s = .{ .tickets = tickets };
        },
        1 => { // Keys state
            const keys = try allocator.alloc(types.BandersnatchPublic, params.epoch_length);
            errdefer allocator.free(keys);

            const kbuffer: []u8 = std.mem.sliceAsBytes(keys);
            reader.readNoEof(kbuffer) catch |err| {
                return context.makeError(error.EndOfStream, "failed to read keys: {s}", .{@errorName(err)});
            };

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
