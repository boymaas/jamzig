comptime {
    _ = @import("safrole_test.zig");
    _ = @import("safrole/types_test.zig");
    _ = @import("safrole_test/diffz.zig");
}

const std = @import("std");
const tv_types = @import("tests/vectors/libs/types.zig");
const tv_lib_safrole = @import("tests/vectors/libs/safrole.zig");

const lib_safrole = @import("safrole/types.zig");

pub const hexStringToBytes = tv_types.hex.hexStringToBytes;

const Error = error{ FromError, OutOfMemory };
const Allocator = std.mem.Allocator;

/// Maps the type from the testVector to a safrole implementation type
pub fn stateFromTestVector(allocator: Allocator, from: *const tv_lib_safrole.State) Error!lib_safrole.State {
    return lib_safrole.State{
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

pub fn inputFromTestVector(allocator: Allocator, from: *const tv_lib_safrole.Input) Error!lib_safrole.Input {
    var to = lib_safrole.Input{
        .slot = from.slot,
        .entropy = convertOpaqueHash(from.entropy),
        .extrinsic = undefined,
    };

    to.extrinsic = try allocator.alloc(lib_safrole.TicketEnvelope, from.extrinsic.len);
    for (from.extrinsic, to.extrinsic) |from_envelope, *to_envelope| {
        to_envelope.attempt = from_envelope.attempt;
        convertHexBytesToArray(784, from_envelope.signature, &to_envelope.signature);
    }

    return to;
}

pub fn outputFromTestVector(allocator: Allocator, from: *const tv_lib_safrole.Output) Error!lib_safrole.Output {
    return switch (from.*) {
        .err => |err| lib_safrole.Output{ .err = try convertOutputError(err) },
        .ok => |marks| lib_safrole.Output{
            .ok = lib_safrole.OutputMarks{
                .epoch_mark = if (marks.epoch_mark) |epoch_mark|
                    try convertEpochMark(allocator, epoch_mark)
                else
                    null,
                .tickets_mark = if (marks.tickets_mark) |tickets_mark|
                    try convertTicketBodySlice(allocator, tickets_mark)
                else
                    null,
            },
        },
    };
}

fn convertOutputError(from: ?[]const u8) Error!lib_safrole.OutputError {
    if (from) |err_str| {
        inline for (@typeInfo(lib_safrole.OutputError).@"enum".fields) |field| {
            if (std.mem.eql(u8, err_str, field.name)) {
                return @field(lib_safrole.OutputError, field.name);
            }
        }
    }
    return error.FromError;
}

fn convertEpochMark(allocator: Allocator, from: tv_lib_safrole.EpochMark) Error!lib_safrole.EpochMark {
    return lib_safrole.EpochMark{
        .entropy = convertOpaqueHash(from.entropy),
        .validators = try convertBandersnatchKeysSlice(allocator, from.validators),
    };
}

fn convertEta(from: [4]tv_lib_safrole.OpaqueHash) [4]lib_safrole.OpaqueHash {
    return .{
        convertOpaqueHash(from[0]),
        convertOpaqueHash(from[1]),
        convertOpaqueHash(from[2]),
        convertOpaqueHash(from[3]),
    };
}

fn convertOpaqueHash(from: tv_lib_safrole.OpaqueHash) lib_safrole.OpaqueHash {
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

fn convertValidatorDataSlice(allocator: Allocator, from: []tv_lib_safrole.ValidatorData) Error![]lib_safrole.ValidatorData {
    const to = try allocator.alloc(lib_safrole.ValidatorData, from.len);
    for (from, to) |*from_validator, *to_validator| {
        convertValidatorData(from_validator, to_validator);
    }
    return to;
}

fn convertValidatorData(from: *tv_lib_safrole.ValidatorData, to: *lib_safrole.ValidatorData) void {
    convertHexBytesToArray(32, from.bandersnatch, &to.bandersnatch);
    convertHexBytesToArray(32, from.ed25519, &to.ed25519);
    convertHexBytesToArray(144, from.bls, &to.bls);
    convertHexBytesToArray(128, from.metadata, &to.metadata);
}

fn convertTicketBodySlice(allocator: Allocator, from: []tv_lib_safrole.TicketBody) Error![]lib_safrole.TicketBody {
    const to = try allocator.alloc(lib_safrole.TicketBody, from.len);
    for (from, to) |from_ticket, *to_ticket| {
        to_ticket.* = convertTicketBody(from_ticket);
    }
    return to;
}

fn convertTicketBody(from: tv_lib_safrole.TicketBody) lib_safrole.TicketBody {
    return lib_safrole.TicketBody{
        .id = convertOpaqueHash(from.id),
        .attempt = from.attempt,
    };
}

fn convertGammaS(allocator: Allocator, from: tv_lib_safrole.GammaS) Error!lib_safrole.GammaS {
    switch (from) {
        .tickets => {
            return lib_safrole.GammaS{ .tickets = try convertTicketBodySlice(allocator, from.tickets) };
        },
        .keys => {
            return lib_safrole.GammaS{ .keys = try convertBandersnatchKeysSlice(allocator, from.keys) };
        },
    }
}

fn convertBandersnatchKeysSlice(allocator: Allocator, from: []tv_lib_safrole.BandersnatchKey) Error![]lib_safrole.BandersnatchKey {
    const to = try allocator.alloc(lib_safrole.BandersnatchKey, from.len);
    for (from, to) |from_key, *to_key| {
        to_key.* = convertHexBytesFixedToArray(32, from_key);
    }
    return to;
}

fn convertGammaZ(from: tv_lib_safrole.GammaZ) lib_safrole.GammaZ {
    return convertHexBytesFixedToArray(144, from);
}
