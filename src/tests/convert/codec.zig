const std = @import("std");
const tv_types = @import("../vectors/libs/types.zig");
const tv_lib_codec = @import("../vectors/libs/codec.zig");

const lib_codec = @import("../../types.zig");

const Allocator = std.mem.Allocator;

pub const generic = @import("generic.zig");

/// Mapping between types in the test vector and the codec.
const TypeMapping = struct {
    pub fn @"HexBytesFixed(32)"(from: tv_types.hex.HexBytesFixed(32)) [32]u8 {
        return convertHexBytesFixedToArray(32, from);
    }

    pub fn @"HexBytesFixed(96)"(from: tv_types.hex.HexBytesFixed(96)) [96]u8 {
        return convertHexBytesFixedToArray(96, from);
    }

    pub fn TicketBody(allocator: Allocator, from: []const tv_lib_codec.TicketBody) !lib_codec.TicketsMark {
        var tickets = try allocator.alloc(lib_codec.TicketBody, from.len);
        for (from, 0..) |ticket, i| {
            tickets[i] = convertTicketBody(ticket);
        }
        return lib_codec.TicketsMark{ .tickets = tickets };
    }
};

/// Convert a `testvecor.Header` to a `codec.Header`.
pub fn convertHeader(allocator: Allocator, from: tv_lib_codec.Header) !lib_codec.Header {
    return try generic.convert(lib_codec.Header, TypeMapping, allocator, from);
}

/// Convert a `testvecor.<any>` to a `codec.<any>`.
pub fn convert(comptime From: type, comptime To: type, allocator: Allocator, from: From) !To {
    return try generic.convert(To, TypeMapping, allocator, from);
}

// Utilities
fn convertHexBytesFixedToArray(comptime size: u32, from: tv_types.hex.HexBytesFixed(size)) [size]u8 {
    var to: [size]u8 = undefined;
    for (from.bytes, 0..) |from_byte, i| {
        to[i] = from_byte;
    }
    return to;
}

fn convertTicketBody(from: tv_lib_codec.TicketBody) lib_codec.TicketBody {
    return lib_codec.TicketBody{
        .id = convertHexBytesFixedToArray(32, from.id),
        .attempt = from.attempt,
    };
}
