const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

const HexBytes = types.hex.HexBytes;
const Ed25519Key = types.hex.HexBytesFixed(32);
const BandersnatchKey = types.hex.HexBytesFixed(32);
const OpaqueHash = types.hex.HexBytesFixed(32);

const TicketOrKey = union { tickets: []TicketBody, keys: []BandersnatchKey };

const TicketBody = struct {
    id: OpaqueHash,
    attempt: u8,
};

const TicketEnvelope = struct {
    attempt: u8,
    signature: HexBytes,
};

const ValidatorData = struct {
    bandersnatch: HexBytes,
    ed25519: HexBytes,
    bls: HexBytes,
    metadata: HexBytes,
};

// TODO: Make a custom type to handle TicketOrKey
const GammaS = struct {
    keys: []BandersnatchKey,
};

const GammaZ = types.hex.HexBytesFixed(144);

const State = struct {
    tau: u32,
    eta: [4]OpaqueHash,
    lambda: []ValidatorData,
    kappa: []ValidatorData,
    gamma_k: []ValidatorData,
    iota: []ValidatorData,
    gamma_a: []TicketBody,
    gamma_s: GammaS,
    gamma_z: GammaZ,
};

const Input = struct {
    slot: u32,
    entropy: OpaqueHash,
    extrinsic: []TicketEnvelope,
};

const Output = struct {
    err: ?[]u8,
};

pub const TestVector = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(allocator: Allocator, file_path: []const u8) !json.Parsed(TestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }

        return try json.parseFromSlice(TestVector, allocator, buffer, .{ .ignore_unknown_fields = true, .parse_numbers = false });
    }
};
