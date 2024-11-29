const std = @import("std");
const tvector = @import("../tests/vectors/libs/disputes.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");

const disputes = @import("../disputes.zig");

pub fn convertValidatorData(allocator: std.mem.Allocator, test_data: []tvector.ValidatorData) !types.ValidatorSet {
    var set = try types.ValidatorSet.init(allocator, @intCast(test_data.len));
    var result = set.items();

    for (test_data, 0..) |data, i| {
        result[i] = .{
            .bandersnatch = data.bandersnatch.bytes,
            .ed25519 = data.ed25519.bytes,
            .bls = data.bls.bytes,
            .metadata = data.metadata.bytes,
        };
    }

    return set;
}

pub fn convertPsi(allocator: std.mem.Allocator, test_psi: tvector.DisputesRecords) !state.Psi {
    var good_set = std.AutoHashMap(disputes.Hash, void).init(allocator);
    for (test_psi.psi_g) |hash| {
        try good_set.put(hash.bytes, {});
    }

    var bad_set = std.AutoHashMap(disputes.Hash, void).init(allocator);
    for (test_psi.psi_b) |hash| {
        try bad_set.put(hash.bytes, {});
    }

    var wonky_set = std.AutoHashMap(disputes.Hash, void).init(allocator);
    for (test_psi.psi_w) |hash| {
        try wonky_set.put(hash.bytes, {});
    }

    var punish_set = std.AutoHashMap(disputes.PublicKey, void).init(allocator);
    for (test_psi.psi_o) |key| {
        try punish_set.put(key.bytes, {});
    }

    return state.Psi{
        .good_set = good_set,
        .bad_set = bad_set,
        .wonky_set = wonky_set,
        .punish_set = punish_set,
    };
}

pub fn convertDisputesExtrinsic(allocator: std.mem.Allocator, test_disputes: tvector.DisputesXt) !types.DisputesExtrinsic {
    var verdicts = try allocator.alloc(types.Verdict, test_disputes.verdicts.len);
    errdefer allocator.free(verdicts);

    for (test_disputes.verdicts, 0..) |test_verdict, i| {
        var votes = try allocator.alloc(types.Judgement, test_verdict.votes.len);
        errdefer allocator.free(votes);

        for (test_verdict.votes, 0..) |test_vote, j| {
            votes[j] = .{
                .vote = test_vote.vote,
                .index = test_vote.index,
                .signature = test_vote.signature.bytes,
            };
        }

        verdicts[i] = .{
            .target = test_verdict.target.bytes,
            .age = test_verdict.age,
            .votes = votes,
        };
    }

    var culprits = try allocator.alloc(types.Culprit, test_disputes.culprits.len);
    errdefer allocator.free(culprits);

    for (test_disputes.culprits, 0..) |test_culprit, i| {
        culprits[i] = .{
            .target = test_culprit.target.bytes,
            .key = test_culprit.key.bytes,
            .signature = test_culprit.signature.bytes,
        };
    }

    var faults = try allocator.alloc(types.Fault, test_disputes.faults.len);
    errdefer allocator.free(faults);

    for (test_disputes.faults, 0..) |test_fault, i| {
        faults[i] = .{
            .target = test_fault.target.bytes,
            .vote = test_fault.vote,
            .key = test_fault.key.bytes,
            .signature = test_fault.signature.bytes,
        };
    }

    return types.DisputesExtrinsic{
        .verdicts = verdicts,
        .culprits = culprits,
        .faults = faults,
    };
}

const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;

pub fn convertRho(comptime core_count: u16, allocator: std.mem.Allocator, test_rho: tvector.AvailabilityAssignments) !state.Rho(core_count) {
    _ = allocator;

    var rho = state.Rho(core_count).init();

    for (test_rho, 0..) |assignment, core| {
        if (assignment) |a| {
            const work_report = createEmptyWorkReport(a.dummy_work_report.bytes[0..32].*);
            var work_report_hash: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b(256).hash(&a.dummy_work_report.bytes, &work_report_hash, .{});
            rho.setReport(core, work_report_hash, work_report, a.timeout);
        }
    }

    return rho;
}
