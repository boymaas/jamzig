const std = @import("std");
const types = @import("../types.zig");

/// Represents a Safrole state of the system as referenced in the GP γ.
pub const Gamma = struct {
    /// τ: The most recent block's timeslot, crucial for maintaining the temporal
    /// context in block production.
    tau: types.TimeSlot,

    /// η: The entropy accumulator, which contributes to the system's randomness
    /// and is updated with each block.
    eta: types.Eta,

    /// λ: Validator keys and metadata from the previous epoch, essential for
    /// ensuring continuity and validating current operations.
    lambda: types.Lambda,

    /// κ: Validator keys and metadata that are currently active, representing the
    /// validators responsible for the current epoch.
    kappa: types.Kappa,

    /// γₖ: The keys for the validators of the next epoch, which help in planning
    /// the upcoming validation process.
    gamma_k: types.GammaK,

    /// ι: Validator keys and metadata to be drawn from next, which indicates the
    /// future state and validators likely to be active.
    iota: types.Iota,

    /// γₐ: The sealing lottery ticket accumulator, part of the process ensuring
    /// randomness and fairness in block sealing.
    gamma_a: types.GammaA,

    /// γₛ: the current epoch’s slot-sealer series, which is either a
    // full complement of E tickets or, in the case of a fallback
    // mode, a series of E Bandersnatch keys
    gamma_s: types.GammaS,

    /// γ𝑧: The Bandersnatch root for the current epoch’s ticket submissions,
    /// which is a cryptographic commitment to the current state of ticket
    /// submissions.
    gamma_z: types.GammaZ,

    /// Frees all allocated memory in the State struct.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.lambda.deinit(allocator);
        self.kappa.deinit(allocator);
        self.gamma_k.deinit(allocator);
        self.iota.deinit(allocator);

        allocator.free(self.gamma_a);

        self.gamma_s.deinit(allocator);
        self.* = undefined;
    }

    /// Creates a deep clone of the State struct.
    pub fn deepClone(self: *const State, allocator: std.mem.Allocator) !State {
        return State{
            .tau = self.tau,
            .eta = self.eta,
            .lambda = try self.lambda.deepClone(allocator),
            .kappa = try self.kappa.deepClone(allocator),
            .gamma_k = try self.gamma_k.deepClone(allocator),
            .iota = try self.iota.deepClone(allocator),
            .gamma_a = try allocator.dupe(types.TicketBody, self.gamma_a),
            .gamma_s = try self.gamma_s.deepClone(allocator),
            .gamma_z = self.gamma_z,
        };
    }
};

/// Represents a Safrole state of the system as referenced in the GP γ.
pub const State = struct {
    gamma: Gamma,

    post_offenders: []types.Ed25519Public,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.gamma.deinit(allocator);
        allocator.free(self.post_offenders);
        self.* = undefined;
    }
};

pub const Input = struct {
    slot: types.TimeSlot,
    entropy: types.Entropy,
    extrinsic: types.TicketsExtrinsic,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.extrinsic.deinit(allocator);
        self.* = undefined;
    }
};

pub const ErrorCode = enum(u8) {
    bad_slot = 0,
    unexpected_ticket = 1,
    bad_ticket_order = 2,
    bad_ticket_proof = 3,
    bad_ticket_attempt = 4,
    reserved = 5,
    duplicate_ticket = 6,
};

pub const Output = union(enum) {
    ok: OutputMarks,
    err: ErrorCode,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => self.ok.deinit(allocator),
            .err => _ = self.err,
        }
        self.* = undefined;
    }

    pub fn format(
        self: Output,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .err => try writer.print("err = {s}", .{@tagName(self.err)}),
            .ok => |marks| try writer.print("ok = {any}", .{marks}),
        }
    }
};

const OutputErr = ?[]u8;

pub const OutputMarks = struct {
    epoch_mark: ?types.EpochMark,
    tickets_mark: ?types.TicketsMark,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.epoch_mark) |*em| em.deinit(allocator);
        if (self.tickets_mark) |*tm| tm.deinit(allocator);
        self.* = undefined;
    }

    pub fn format(
        self: OutputMarks,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const epoch_len = if (self.epoch_mark) |epoch| epoch.validators.len else 0;
        const tickets_len = if (self.tickets_mark) |tickets| tickets.tickets.len else 0;

        try writer.print("epoch_mark.len = {}, tickets_mark.len = {}", .{ epoch_len, tickets_len });
    }
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.pre_state.deinit(allocator);
        self.output.deinit(allocator);
        self.post_state.deinit(allocator);
        self.* = undefined;
    }
};

test "parse.safrole.tiny" {
    const dir = @import("dir.zig");
    const testing = std.testing;

    const TINY = @import("../jam_params.zig").TINY_PARAMS;

    var test_cases = try dir.scan(TestCase, TINY, testing.allocator, "src/jamtestvectors/data/stf/safrole/tiny");
    defer test_cases.deinit();
}

test "parse.safrole.full" {
    const dir = @import("dir.zig");
    const testing = std.testing;

    const FULL = @import("../jam_params.zig").FULL_PARAMS;

    var test_cases = try dir.scan(TestCase, FULL, testing.allocator, "src/jamtestvectors/data/stf/safrole/full");
    defer test_cases.deinit();
}

const loader = @import("loader.zig");
const OrderedFiles = @import("../tests/ordered_files.zig");
const codec = @import("../codec.zig");
const slurp = @import("../tests/slurp.zig");
const Params = @import("../jam_params.zig").Params;

fn testSafroleRoundtrip(comptime params: Params, test_dir: []const u8, allocator: std.mem.Allocator) !void {
    var ordered_files = try OrderedFiles.getOrderedFiles(allocator, test_dir);
    defer ordered_files.deinit();

    for (ordered_files.items()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bin")) {
            continue;
        }

        var test_case = try loader.loadAndDeserializeTestVector(TestCase, params, allocator, entry.path);
        defer test_case.deinit(allocator);

        const binary_serialized = try codec.serializeAlloc(TestCase, params, allocator, test_case);
        defer allocator.free(binary_serialized);

        var binary_loaded = try slurp.slurpFile(allocator, entry.path);
        defer binary_loaded.deinit();

        try std.testing.expectEqualSlices(u8, binary_loaded.buffer, binary_serialized);
        std.debug.print("Successfully validated {s}\n", .{entry.path});
    }
}

test "parse.safrole.tiny.deserialize-serialize-roundtrip" {
    const TINY = @import("../jam_params.zig").TINY_PARAMS;
    try testSafroleRoundtrip(TINY, "src/jamtestvectors/data/stf/safrole/tiny", std.testing.allocator);
}

test "parse.safrole.full.deserialize-serialize-roundtrip" {
    const FULL = @import("../jam_params.zig").FULL_PARAMS;
    try testSafroleRoundtrip(FULL, "src/jamtestvectors/data/stf/safrole/full", std.testing.allocator);
}
