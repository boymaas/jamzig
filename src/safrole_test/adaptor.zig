/// Adapts the TestVector format to our transition function
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Params = @import("../jam_params.zig").Params;
pub const types = @import("../types.zig");
pub const safrole_types = @import("../safrole/types.zig");

// Constant
pub const TransitionResult = struct {
    output: Output,
    state: ?safrole_types.State,

    pub fn deinit(self: TransitionResult, allocator: std.mem.Allocator) void {
        if (self.state != null) {
            self.state.?.deinit(allocator);
        }
        self.output.deinit(allocator);
    }
};

// Input for Safrole protocol.
pub const Input = struct {
    // Current slot.
    slot: u32,
    // Per block entropy (originated from block entropy source VRF).
    entropy: types.OpaqueHash,
    // Safrole extrinsic.
    extrinsic: []types.TicketEnvelope,

    /// Frees all allocated memory in the Input struct.
    pub fn deinit(self: Input, allocator: Allocator) void {
        allocator.free(self.extrinsic);
    }

    /// Implement the default format function
    pub fn format(
        self: Input,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // TODO: move the format functions
        try @import("../safrole/types/format.zig").formatInput(self, writer);
    }
};

pub const Output = union(enum) {
    err: OutputError,
    ok: OutputMarks,

    /// Frees all allocated memory in the Output struct.
    pub fn deinit(self: Output, allocator: Allocator) void {
        switch (self) {
            .err => {},
            .ok => |marks| {
                if (marks.epoch_mark) |epoch_mark| {
                    allocator.free(epoch_mark.validators);
                }
                if (marks.tickets_mark) |tickets_mark| {
                    allocator.free(tickets_mark.tickets);
                }
            },
        }
    }

    /// Implement the default format function
    pub fn format(
        self: Output,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try @import("../safrole/types/format.zig").formatOutput(self, writer);
    }
};

pub const OutputError = enum(u8) {
    /// Bad slot value.
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

    /// MY OWN ERROR CODES
    too_many_tickets_in_extrinsic = 100,
};

pub const OutputMarks = struct {
    epoch_mark: ?types.EpochMark,
    tickets_mark: ?types.TicketsMark,
};

pub fn transition(
    allocator: std.mem.Allocator,
    params: Params,
    pre_state: safrole_types.State,
    input: Input,
) !TransitionResult {
    const result = @import("../safrole.zig").transition(
        allocator,
        params,
        pre_state,
        input.slot,
        input.entropy,
        input.extrinsic,
    ) catch |e| {
        const test_vector_error = switch (e) {
            error.bad_slot => OutputError.bad_slot,
            error.unexpected_ticket => OutputError.unexpected_ticket,
            error.bad_ticket_order => OutputError.bad_ticket_order,
            error.bad_ticket_proof => OutputError.bad_ticket_proof,
            error.bad_ticket_attempt => OutputError.bad_ticket_attempt,
            error.duplicate_ticket => OutputError.duplicate_ticket,
            error.too_many_tickets_in_extrinsic => OutputError.too_many_tickets_in_extrinsic,
            else => @panic("unmapped error"),
        };
        return .{
            .output = .{ .err = test_vector_error },
            .state = null,
        };
    };

    return .{
        .output = .{
            .ok = OutputMarks{
                .epoch_mark = result.epoch_marker,
                .tickets_mark = result.ticket_marker,
            },
        },
        .state = result.post_state,
    };
}
