const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");

const Params = @import("../jam_params.zig").Params;
const StateTransition = @import("../state_delta.zig").StateTransition;

const reports = @import("../reports.zig");

const trace = @import("tracing").scoped(.reports);

pub const Error = error{};

pub const ReportsResult = struct {
    result: reports.Result,

    pub fn getReporters(self: *const ReportsResult) []const types.Ed25519Public {
        return self.result.reporters;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub fn transition(
    comptime params: Params,
    allocator: std.mem.Allocator,
    stx: *StateTransition(params),
    block: *const types.Block,
) !ReportsResult {
    const span = trace.span(@src(), .reports);
    defer span.deinit();

    const validated = try reports.ValidatedGuaranteeExtrinsic.validate(
        params,
        allocator,
        stx,
        block.extrinsic.guarantees,
    );

    var result = try reports.processGuaranteeExtrinsic(
        params,
        allocator,
        stx,
        validated,
    );
    errdefer result.deinit(allocator);

    // Return reporters as Ed25519 keys (set M from graypaper)
    // validator_stats will iterate κ' and check membership per GP statistics.tex
    return .{ .result = result };
}
