const std = @import("std");
const state = @import("../state.zig");
const types = @import("../types.zig");

const disputes = @import("../disputes.zig");

pub fn convertPsi(allocator: std.mem.Allocator, records: types.DisputesRecords) !state.Psi {
    var psi = state.Psi.init(allocator);
    errdefer psi.deinit();

    for (records.good) |hash| {
        try psi.good_set.put(hash, {});
    }

    for (records.bad) |hash| {
        try psi.bad_set.put(hash, {});
    }

    for (records.wonky) |hash| {
        try psi.wonky_set.put(hash, {});
    }

    for (records.offenders) |key| {
        try psi.punish_set.put(key, {});
    }

    return psi;
}

const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;

pub fn convertRho(comptime core_count: u16, allocator: std.mem.Allocator, assignments: types.AvailabilityAssignments) !state.Rho(core_count) {
    var rho = state.Rho(core_count).init(allocator);
    for (assignments.items, 0..) |assignment, core| {
        if (assignment) |a| {
            rho.setReport(core, try a.deepClone(allocator));
        }
    }
    return rho;
}
