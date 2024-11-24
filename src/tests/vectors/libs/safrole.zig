const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

pub const HexBytes = types.hex.HexBytes;
pub const HexBytesFixed = types.hex.HexBytesFixed;
pub const Ed25519Key = types.hex.HexBytesFixed(32);
pub const BandersnatchPublic = types.hex.HexBytesFixed(32);
pub const OpaqueHash = types.hex.HexBytesFixed(32);

pub const TicketOrKey = union(enum) { tickets: []TicketBody, keys: []BandersnatchPublic };

pub const EpochMark = struct {
    entropy: OpaqueHash,
    validators: []BandersnatchPublic,
};

pub const TicketMark = []TicketBody;

pub const TicketBody = struct {
    id: OpaqueHash,
    attempt: u8,
};

pub const TicketEnvelope = struct {
    attempt: u8,
    signature: HexBytes,
};

pub const ValidatorData = struct {
    bandersnatch: HexBytesFixed(32),
    ed25519: HexBytesFixed(32),
    bls: HexBytesFixed(144),
    metadata: HexBytesFixed(128),
};

// TODO: Make a custom type to handle TicketOrKey
// see mark-5
pub const GammaS = TicketOrKey;

pub const GammaZ = types.hex.HexBytesFixed(144);

/// Represents a Safrole state of the system as referenced in the GP γ.
pub const State = struct {
    /// τ: The most recent block's timeslot, crucial for maintaining the temporal
    /// context in block production.
    tau: u32,

    /// η: The entropy accumulator, which contributes to the system's randomness
    /// and is updated with each block.
    eta: [4]OpaqueHash,

    /// λ: Validator keys and metadata from the previous epoch, essential for
    /// ensuring continuity and validating current operations.
    lambda: []ValidatorData,

    /// κ: Validator keys and metadata that are currently active, representing the
    /// validators responsible for the current epoch.
    kappa: []ValidatorData,

    /// γₖ: The keys for the validators of the next epoch, which help in planning
    /// the upcoming validation process.
    gamma_k: []ValidatorData,

    /// ι: Validator keys and metadata to be drawn from next, which indicates the
    /// future state and validators likely to be active.
    iota: []ValidatorData,

    /// γₐ: The sealing lottery ticket accumulator, part of the process ensuring
    /// randomness and fairness in block sealing.
    gamma_a: []TicketBody,

    /// γₛ: The sealing-key sequence for the current epoch, representing the order
    /// and structure of keys used in the sealing process.
    gamma_s: GammaS,

    /// γ𝑧: The Bandersnatch root for the current epoch’s ticket submissions,
    /// which is a cryptographic commitment to the current state of ticket
    /// submissions.
    gamma_z: GammaZ,
};

pub const Input = struct {
    slot: u32,
    entropy: OpaqueHash,
    extrinsic: []TicketEnvelope,
};

pub const Output = union(enum) {
    err: ?[]u8,
    ok: OutputMarks,

    // The JSON defines an output which can be either an Ok variant or an Error variant.
    // This is not supported by default by the Zig JSON parser. As such,
    // we have implemented a custom parser for this. Based on an "ok" value or an "err" value,
    // the union will be filled with either the ok case or the error case.
    pub fn jsonParse(
        allocator: Allocator,
        source: *json.Scanner,
        options: json.ParseOptions,
    ) json.ParseError(json.Scanner)!Output {
        if (.object_begin != try source.next()) return error.UnexpectedToken;

        while (true) {
            const name_token: ?json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            _ = switch (name_token.?) {
                .string, .allocated_string => |slice| {
                    if (std.mem.eql(u8, slice, "err")) {
                        const val = try json.innerParse([]u8, allocator, source, options);
                        if (.object_end != try source.next()) return error.UnexpectedToken;

                        // do something for "err" case
                        return Output{ .err = val };
                    } else if (std.mem.eql(u8, slice, "ok")) {
                        const val = try json.innerParse(OutputMarks, allocator, source, options);
                        if (.object_end != try source.next()) return error.UnexpectedToken;

                        return Output{ .ok = val };
                    } else {
                        return error.UnexpectedToken;
                    }
                },
                .object_end => { // No more fields.
                    break;
                },
                else => {
                    return error.UnexpectedToken;
                },
            };
        }
        unreachable;
    }

    pub fn format(
        self: Output,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .err => try writer.print("err = {?s}", .{self.err}),
            .ok => |marks| try writer.print("ok = {any}", .{marks}),
        }
    }
};

const OutputErr = ?[]u8;

const OutputMarks = struct {
    epoch_mark: ?EpochMark,
    tickets_mark: ?TicketMark,

    pub fn format(
        self: OutputMarks,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const epoch_len = if (self.epoch_mark) |epoch| epoch.validators.len else 0;
        const tickets_len = if (self.tickets_mark) |tickets| tickets.len else 0;

        try writer.print("epoch_mark.len = {}, tickets_mark.len = {}", .{ epoch_len, tickets_len });
    }
};

pub const TestVector = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(TestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }

        return json.parseFromSlice(TestVector, allocator, buffer, .{ .ignore_unknown_fields = true, .parse_numbers = false }) catch |err| {
            std.debug.print("Incompatible TestVector [{s}]: {}\n", .{ file_path, err });
            return err;
        };
    }
};
