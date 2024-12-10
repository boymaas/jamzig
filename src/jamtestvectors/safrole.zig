const std = @import("std");
const types = @import("../types.zig");

/// Represents a Safrole state of the system as referenced in the GP γ.
pub const State = struct {
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

    /// γₛ: The sealing-key sequence for the current epoch, representing the order
    /// and structure of keys used in the sealing process.
    gamma_s: types.GammaS,

    /// γ𝑧: The Bandersnatch root for the current epoch’s ticket submissions,
    /// which is a cryptographic commitment to the current state of ticket
    /// submissions.
    gamma_z: types.GammaZ,

    /// [ψ_o'] Posterior offenders sequence.
    post_offenders: []types.Ed25519Public,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.lambda.deinit(allocator);
        self.kappa.deinit(allocator);
        self.gamma_k.deinit(allocator);
        self.iota.deinit(allocator);
        allocator.free(self.gamma_a);
        self.gamma_s.deinit(allocator);
        allocator.free(self.post_offenders);
    }
};

pub const Input = struct {
    slot: types.TimeSlot,
    entropy: types.Entropy,
    extrinsic: types.TicketsExtrinsic,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.extrinsic);
    }
};

pub const ErrorCode = enum(u8) {
    /// Timeslot value must be strictly monotonic.
    bad_slot = 0,
    /// Received a ticket while in epoch's tail.
    unexpected_ticket = 1,
    /// Tickets must be sorted.
    bad_ticket_order = 2,
    /// Invalid ticket ring proof.
    bad_ticket_proof = 3,
    /// Invalid ticket attempt value.
    bad_ticket_attempt = 4,
    /// Reserved
    reserved = 5,
    /// Found a ticket duplicate.
    duplicate_ticket = 6,
};

pub const Output = union(enum) {
    ok: OutputMarks,
    err: ErrorCode,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => self.ok.deinit(allocator),
            .err => _ = self.err,
        }
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
    epoch_mark: ?types.EpochMark,
    tickets_mark: ?types.TicketsMark,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.epoch_mark) |em| em.deinit(allocator);
        if (self.tickets_mark) |tm| tm.deinit(allocator);
    }

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

const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.pre_state.deinit(allocator);
        self.output.deinit(allocator);
        self.post_state.deinit(allocator);
    }
};

//  _   _       _ _  _____         _
// | | | |_ __ (_) ||_   _|__  ___| |_ ___
// | | | | '_ \| | __|| |/ _ \/ __| __/ __|
// | |_| | | | | | |_ | |  __/\__ \ |_\__ \
//  \___/|_| |_|_|\__||_|\___||___/\__|___/
//

test "parse.safrole.tiny" {
    const dir = @import("dir.zig");
    const testing = std.testing;

    // Initialize allocator for test
    const TINY = @import("../jam_params.zig").TINY_PARAMS;

    var test_cases = try dir.scan(TestCase, TINY, testing.allocator, "src/jamtestvectors/data/safrole/tiny");
    defer test_cases.deinit();
}

test "parse.safrole.full" {
    const dir = @import("dir.zig");
    const testing = std.testing;

    // Initialize allocator for test
    const FULL = @import("../jam_params.zig").FULL_PARAMS;

    var test_cases = try dir.scan(TestCase, FULL, testing.allocator, "src/jamtestvectors/data/safrole/full");
    defer test_cases.deinit();
}

//   ____          _             _____         _
//  / ___|___   __| | ___  ___  |_   _|__  ___| |_ ___
// | |   / _ \ / _` |/ _ \/ __|   | |/ _ \/ __| __/ __|
// | |__| (_) | (_| |  __/ (__    | |  __/\__ \ |_\__ \
//  \____\___/ \__,_|\___|\___|   |_|\___||___/\__|___/

const parser = @import("parser.zig");
const OrderedFiles = @import("../tests/ordered_files.zig");
const codec = @import("../codec.zig");
const slurp = @import("../tests/slurp.zig");
const Params = @import("../jam_params.zig").Params;

fn testSafroleRoundtrip(comptime params: Params, test_dir: []const u8, allocator: std.mem.Allocator) !void {
    // Get ordered list of files
    var ordered_files = try OrderedFiles.getOrderedFiles(allocator, test_dir);
    defer ordered_files.deinit();

    // Process each binary file
    for (ordered_files.items()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".bin")) {
            continue;
        }

        // Load and parse binary file
        var test_case = try parser.parseTestVector(TestCase, params, allocator, entry.path);
        defer test_case.deinit(allocator);

        // Serialize the test case
        const binary_serialized = try codec.serializeAlloc(TestCase, params, allocator, test_case);
        defer allocator.free(binary_serialized);

        // Load original binary for comparison
        var binary_loaded = try slurp.slurpFile(allocator, entry.path);
        defer binary_loaded.deinit();

        // Compare original with serialized version
        try std.testing.expectEqualSlices(u8, binary_loaded.buffer, binary_serialized);
        std.debug.print("Successfully validated {s}\n", .{entry.path});
    }
}

test "parse.safrole.tiny.deserialize-serialize-roundtrip" {
    const TINY = @import("../jam_params.zig").TINY_PARAMS;
    try testSafroleRoundtrip(TINY, "src/jamtestvectors/data/safrole/tiny", std.testing.allocator);
}

test "parse.safrole.full.deserialize-serialize-roundtrip" {
    const FULL = @import("../jam_params.zig").FULL_PARAMS;
    try testSafroleRoundtrip(FULL, "src/jamtestvectors/data/safrole/full", std.testing.allocator);
}
