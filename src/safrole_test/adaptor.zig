/// Adapts the TestVector format to our transition function
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Params = @import("../jam_params.zig").Params;
pub const types = @import("../types.zig");
pub const safrole_types = @import("../safrole/types.zig");
pub const safrole_test_vector = @import("../jamtestvectors/safrole.zig");

pub const safrole = @import("../safrole.zig");

// Constant
pub const TransitionResult = struct {
    output: safrole_test_vector.Output,
    state: ?safrole_types.State,

    pub fn deinit(self: TransitionResult, allocator: std.mem.Allocator) void {
        if (self.state != null) {
            self.state.?.deinit(allocator);
        }
        self.output.deinit(allocator);
    }
};

pub fn transition(
    allocator: std.mem.Allocator,
    params: Params,
    pre_state: safrole_test_vector.State,
    input: safrole_test_vector.Input,
) !TransitionResult {
    const result = safrole.transition(
        allocator,
        params,
        pre_state.gamma,
        input.slot,
        input.entropy,
        input.extrinsic,
        pre_state.post_offenders,
    ) catch |e| {
        const test_vector_error = switch (e) {
            error.bad_slot => safrole_test_vector.ErrorCode.bad_slot,
            error.unexpected_ticket => safrole_test_vector.ErrorCode.unexpected_ticket,
            error.bad_ticket_order => safrole_test_vector.ErrorCode.bad_ticket_order,
            error.bad_ticket_proof => safrole_test_vector.ErrorCode.bad_ticket_proof,
            error.bad_ticket_attempt => safrole_test_vector.ErrorCode.bad_ticket_attempt,
            error.duplicate_ticket => safrole_test_vector.ErrorCode.duplicate_ticket,
            error.too_many_tickets_in_extrinsic => @panic("Unmapped error"),
            else => @panic("unmapped error"),
        };
        return .{
            .output = .{ .err = test_vector_error },
            .state = null,
        };
    };

    return .{
        .output = .{
            .ok = safrole_test_vector.OutputMarks{
                .epoch_mark = result.epoch_marker,
                .tickets_mark = result.ticket_marker,
            },
        },
        .state = result.post_state,
    };
}
