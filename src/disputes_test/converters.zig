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
    for (test_psi.good) |hash| {
        try good_set.put(hash.bytes, {});
    }

    var bad_set = std.AutoHashMap(disputes.Hash, void).init(allocator);
    for (test_psi.bad) |hash| {
        try bad_set.put(hash.bytes, {});
    }

    var wonky_set = std.AutoHashMap(disputes.Hash, void).init(allocator);
    for (test_psi.wonky) |hash| {
        try wonky_set.put(hash.bytes, {});
    }

    var punish_set = std.AutoHashMap(disputes.PublicKey, void).init(allocator);
    for (test_psi.offenders) |key| {
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
    var rho = state.Rho(core_count).init();
    for (test_rho, 0..) |assignment, core| {
        if (assignment) |a| {
            const converted = try convertAvailabilityAssignment(allocator, a);
            rho.setReport(core, converted.report.package_spec.hash, converted.report, converted.timeout);
        }
    }
    return rho;
}

fn convertAvailabilityAssignment(allocator: std.mem.Allocator, test_assignment: tvector.AvailabilityAssignment) !types.AvailabilityAssignment {
    const work_report = try convertWorkReport(allocator, test_assignment.report);
    return types.AvailabilityAssignment{
        .report = work_report,
        .timeout = test_assignment.timeout,
    };
}

fn convertWorkReport(allocator: std.mem.Allocator, test_report: tvector.WorkReport) !types.WorkReport {
    var results = try allocator.alloc(types.WorkResult, test_report.results.len);
    errdefer allocator.free(results);
    for (test_report.results, 0..) |*result, i| {
        results[i] = .{
            .service_id = result.service_id,
            .code_hash = result.code_hash.bytes,
            .payload_hash = result.payload_hash.bytes,
            .gas = result.gas,
            .result = switch (result.result) {
                .ok => |data| .{ .ok = brk: {
                    const clone = try allocator.dupe(u8, data.bytes);
                    errdefer allocator.free(clone);
                    break :brk clone;
                } },
                .out_of_gas => .out_of_gas,
                .panic => .panic,
                .bad_code => .bad_code,
                .code_oversize => .code_oversize,
            },
        };
    }

    var lookup = try allocator.alloc(types.SegmentRootLookupItem, test_report.segment_root_lookup.len);
    for (test_report.segment_root_lookup, 0..) |item, i| {
        lookup[i] = .{
            .work_package_hash = item.work_package_hash.bytes,
            .segment_tree_root = item.segment_tree_root.bytes,
        };
    }

    return types.WorkReport{
        .package_spec = .{
            .hash = test_report.package_spec.hash.bytes,
            .length = test_report.package_spec.length,
            .erasure_root = test_report.package_spec.erasure_root.bytes,
            .exports_root = test_report.package_spec.exports_root.bytes,
            .exports_count = test_report.package_spec.exports_count,
        },
        .context = .{
            .anchor = test_report.context.anchor.bytes,
            .state_root = test_report.context.state_root.bytes,
            .beefy_root = test_report.context.beefy_root.bytes,
            .lookup_anchor = test_report.context.lookup_anchor.bytes,
            .lookup_anchor_slot = test_report.context.lookup_anchor_slot,
            .prerequisites = blk: {
                const prereqs = try allocator.alloc(types.OpaqueHash, test_report.context.prerequisites.len);
                errdefer allocator.free(prereqs);
                for (test_report.context.prerequisites, prereqs) |src, *dst| {
                    dst.* = src.bytes;
                }
                break :blk prereqs;
            },
        },
        .core_index = test_report.core_index,
        .authorizer_hash = test_report.authorizer_hash.bytes,
        .auth_output = brk: {
            const clone = try allocator.dupe(u8, test_report.auth_output.bytes);
            errdefer allocator.free(clone);
            break :brk clone;
        },
        .segment_root_lookup = lookup,
        .results = results,
    };
}
