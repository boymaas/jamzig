const std = @import("std");
const tv_types = @import("../vectors/libs/types.zig");
const tv_lib_safrole = @import("../vectors/libs/safrole.zig");

const adaptor = @import("../../safrole_test/adaptor.zig");
const lib_safrole = @import("../../safrole/types.zig");
const types = @import("../../types.zig");

const Error = error{ FromError, OutOfMemory };
const Allocator = std.mem.Allocator;

/// Maps the type from the testVector to a safrole implementation type
pub fn stateFromTestVector(allocator: Allocator, from: *const tv_lib_safrole.State) Error!lib_safrole.State {
    return .{
        .tau = from.tau,
        .eta = convertEta(from.eta),
        .lambda = try convertValidatorDataSlice(allocator, from.lambda),
        .kappa = try convertValidatorDataSlice(allocator, from.kappa),
        .gamma_k = try convertValidatorDataSlice(allocator, from.gamma_k),
        .iota = try convertValidatorDataSlice(allocator, from.iota),
        .gamma_a = try convertTicketBodySlice(allocator, from.gamma_a),
        .gamma_s = try convertGammaS(allocator, from.gamma_s),
        .gamma_z = convertGammaZ(from.gamma_z),
    };
}

pub fn inputFromTestVector(allocator: Allocator, from: *const tv_lib_safrole.Input) Error!adaptor.Input {
    var to = adaptor.Input{
        .slot = from.slot,
        .entropy = convertOpaqueHash(from.entropy),
        .extrinsic = undefined,
    };

    to.extrinsic = try allocator.alloc(types.TicketEnvelope, from.extrinsic.len);
    for (from.extrinsic, to.extrinsic) |from_envelope, *to_envelope| {
        to_envelope.attempt = from_envelope.attempt;
        convertHexBytesToArray(784, from_envelope.signature, &to_envelope.signature);
    }

    return to;
}

pub fn outputFromTestVector(allocator: Allocator, from: *const tv_lib_safrole.Output) Error!adaptor.Output {
    return switch (from.*) {
        .err => |err| adaptor.Output{ .err = try convertOutputError(err) },
        .ok => |marks| adaptor.Output{
            .ok = adaptor.OutputMarks{
                .epoch_mark = if (marks.epoch_mark) |epoch_mark|
                    try convertEpochMark(allocator, epoch_mark)
                else
                    null,
                .tickets_mark = if (marks.tickets_mark) |tickets_mark|
                    .{ .tickets = try convertTicketBodySlice(allocator, tickets_mark) }
                else
                    null,
            },
        },
    };
}

fn convertOutputError(from: ?[]const u8) Error!adaptor.OutputError {
    if (from) |err_str| {
        inline for (@typeInfo(adaptor.OutputError).@"enum".fields) |field| {
            if (std.mem.eql(u8, err_str, field.name)) {
                return @field(adaptor.OutputError, field.name);
            }
        }
    }
    return error.FromError;
}

fn convertEpochMark(allocator: Allocator, from: tv_lib_safrole.EpochMark) Error!types.EpochMark {
    return types.EpochMark{
        .entropy = convertOpaqueHash(from.entropy),
        .tickets_entropy = convertOpaqueHash(from.entropy), // FIX: this must be fixed, testvectors out of alignment, new safrole tv should contain tickets_entropy
        .validators = try convertBandersnatchKeysSlice(allocator, from.validators),
    };
}

fn convertEta(from: [4]tv_lib_safrole.OpaqueHash) [4]types.OpaqueHash {
    return .{
        convertOpaqueHash(from[0]),
        convertOpaqueHash(from[1]),
        convertOpaqueHash(from[2]),
        convertOpaqueHash(from[3]),
    };
}

fn convertOpaqueHash(from: tv_lib_safrole.OpaqueHash) types.OpaqueHash {
    return convertHexBytesFixedToArray(32, from);
}

fn convertHexBytesFixedToArray(comptime size: u32, from: tv_types.hex.HexBytesFixed(size)) [size]u8 {
    var to: [size]u8 = undefined;
    for (from.bytes, 0..) |from_byte, i| {
        to[i] = from_byte;
    }
    return to;
}

fn convertHexBytesToArray(comptime size: u32, from: tv_types.hex.HexBytes, to: *[size]u8) void {
    std.debug.assert(from.bytes.len == size);

    for (from.bytes, 0..) |from_byte, i| {
        to[i] = from_byte;
    }
}

fn convertValidatorDataSlice(allocator: Allocator, from: []tv_lib_safrole.ValidatorData) Error!types.ValidatorSet {
    const to = try types.ValidatorSet.init(allocator, @intCast(from.len));
    for (from, to.items()) |*from_validator, *to_validator| {
        convertValidatorData(from_validator, to_validator);
    }
    return to;
}

fn convertValidatorData(from: *tv_lib_safrole.ValidatorData, to: *types.ValidatorData) void {
    to.bandersnatch = convertHexBytesFixedToArray(32, from.bandersnatch);
    to.ed25519 = convertHexBytesFixedToArray(32, from.ed25519);
    to.bls = convertHexBytesFixedToArray(144, from.bls);
    to.metadata = convertHexBytesFixedToArray(128, from.metadata);
}

fn convertTicketBodySlice(allocator: Allocator, from: []tv_lib_safrole.TicketBody) Error![]types.TicketBody {
    const to = try allocator.alloc(types.TicketBody, from.len);
    for (from, to) |from_ticket, *to_ticket| {
        to_ticket.* = convertTicketBody(from_ticket);
    }
    return to;
}

fn convertTicketBody(from: tv_lib_safrole.TicketBody) types.TicketBody {
    return types.TicketBody{
        .id = convertOpaqueHash(from.id),
        .attempt = from.attempt,
    };
}

fn convertGammaS(allocator: Allocator, from: tv_lib_safrole.GammaS) Error!types.GammaS {
    switch (from) {
        .tickets => {
            return types.GammaS{ .tickets = try convertTicketBodySlice(allocator, from.tickets) };
        },
        .keys => {
            return types.GammaS{ .keys = try convertBandersnatchKeysSlice(allocator, from.keys) };
        },
    }
}

fn convertBandersnatchKeysSlice(allocator: Allocator, from: []tv_lib_safrole.BandersnatchPublic) Error![]types.BandersnatchPublic {
    const to = try allocator.alloc(types.BandersnatchPublic, from.len);
    for (from, to) |from_key, *to_key| {
        to_key.* = convertHexBytesFixedToArray(32, from_key);
    }
    return to;
}

fn convertGammaZ(from: tv_lib_safrole.GammaZ) types.GammaZ {
    return convertHexBytesFixedToArray(144, from);
}
