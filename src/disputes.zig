const std = @import("std");
const Allocator = std.mem.Allocator;
const ed25519 = @import("crypto/ed25519.zig").Ed25519;

const trace = @import("tracing").scoped(.disputes);

// Types
pub const Hash = [32]u8;
pub const Signature = [64]u8;
pub const PublicKey = [32]u8;

const types = @import("types.zig");

pub const Judgment = types.Judgement;
pub const Verdict = types.Verdict;
pub const Culprit = types.Culprit;
pub const Fault = types.Fault;
pub const DisputesExtrinsic = types.DisputesExtrinsic;

pub const Rho = @import("state.zig").Rho;

pub const Psi = struct {
    good_set: std.AutoArrayHashMap(Hash, void),
    bad_set: std.AutoArrayHashMap(Hash, void),
    wonky_set: std.AutoArrayHashMap(Hash, void),
    punish_set: std.AutoArrayHashMap(PublicKey, void),

    pub fn init(allocator: Allocator) Psi {
        return Psi{
            .good_set = std.AutoArrayHashMap(Hash, void).init(allocator),
            .bad_set = std.AutoArrayHashMap(Hash, void).init(allocator),
            .wonky_set = std.AutoArrayHashMap(Hash, void).init(allocator),
            .punish_set = std.AutoArrayHashMap(PublicKey, void).init(allocator),
        };
    }

    // Register an offender
    // TODO: add the test
    pub fn registerOffender(self: *Psi, key: PublicKey) !void {
        if (self.punish_set.contains(key)) {
            return error.OffenderAlreadyReported;
        }
        try self.punish_set.put(key, {});
    }

    // Register a set of offenders
    // TODO: add the test
    pub fn registerOffenders(self: *Psi, keys: []const PublicKey) !void {
        for (keys) |key| {
            try self.registerOffender(key);
        }
    }

    // Get offenders slice - no allocation, slice is owned by Psi
    pub fn offendersSlice(self: *const Psi) []const PublicKey {
        return self.punish_set.keys();
    }

    pub fn isOffender(self: *const Psi, key: PublicKey) bool {
        return self.punish_set.contains(key);
    }

    // Get offenders with allocation (when ownership is needed)
    pub fn offendersOwned(self: *const Psi, allocator: Allocator) ![]PublicKey {
        return try allocator.dupe(PublicKey, self.punish_set.keys());
    }

    // Deep clone functionality
    pub fn deepClone(self: *const Psi) !Psi {
        return Psi{
            .good_set = try self.good_set.clone(),
            .bad_set = try self.bad_set.clone(),
            .wonky_set = try self.wonky_set.clone(),
            .punish_set = try self.punish_set.clone(),
        };
    }

    pub fn deinit(self: *Psi) void {
        self.good_set.deinit();
        self.bad_set.deinit();
        self.wonky_set.deinit();
        self.punish_set.deinit();
        self.* = undefined;
    }

    // Format implementation
    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const tfmt = @import("types/fmt.zig");
        const formatter = tfmt.Format(@TypeOf(self.*)){
            .value = self.*,
            .options = .{},
        };
        try formatter.format(fmt, options, writer);
    }
};

// Process disputes extrinsic implementation
pub fn processDisputesExtrinsic(
    comptime core_count: u32,
    psi_prime: *Psi,
    rho_prime: *Rho(core_count),
    extrinsic: DisputesExtrinsic,
    validator_count: usize,
) !void {
    // Safety assertions
    std.debug.assert(core_count > 0);
    std.debug.assert(validator_count > 0);

    const span = trace.span(@src(), .process_disputes);
    defer span.deinit();
    span.debug("Processing disputes extrinsic with {d} validators", .{validator_count});
    span.debug("Verdicts count: {d}, Culprits: {d}, Faults: {d}", .{
        extrinsic.verdicts.len,
        extrinsic.culprits.len,
        extrinsic.faults.len,
    });

    // Process verdicts
    for (extrinsic.verdicts, 0..) |verdict, i| {
        const verdict_span = span.child(@src(), .process_verdict);
        defer verdict_span.deinit();
        verdict_span.debug("Processing verdict {d} of {d}", .{ i + 1, extrinsic.verdicts.len });
        verdict_span.trace("Target hash: {s}", .{std.fmt.fmtSliceHexLower(&verdict.target)});

        const positive_judgments = countPositiveJudgments(verdict);
        verdict_span.debug("Positive judgments: {d}", .{positive_judgments});

        if (positive_judgments == validator_count * 2 / 3 + 1) {
            verdict_span.debug("Adding to good set - supermajority positive", .{});
            try psi_prime.good_set.put(verdict.target, {});
        } else if (positive_judgments == 0) {
            verdict_span.debug("Adding to bad set - unanimous negative", .{});
            try psi_prime.bad_set.put(verdict.target, {});
            verdict_span.debug("Clearing from core", .{});
            _ = try rho_prime.clearFromCore(verdict.target);
        } else if (positive_judgments == validator_count / 3) {
            verdict_span.debug("Adding to wonky set - threshold negative", .{});
            try psi_prime.wonky_set.put(verdict.target, {});
            verdict_span.debug("Clearing from core", .{});
            _ = try rho_prime.clearFromCore(verdict.target);
        }
    }

    // Clear punish set before processing new offenders
    psi_prime.punish_set.clearRetainingCapacity();

    // Process culprits
    const culprits_span = span.child(@src(), .process_culprits);
    defer culprits_span.deinit();
    culprits_span.debug("Processing {d} culprits", .{extrinsic.culprits.len});

    for (extrinsic.culprits, 0..) |culprit, i| {
        const culprit_span = culprits_span.child(@src(), .culprit);
        defer culprit_span.deinit();
        culprit_span.debug("Processing culprit {d} of {d}", .{ i + 1, extrinsic.culprits.len });
        culprit_span.trace("Public key: {s}", .{std.fmt.fmtSliceHexLower(&culprit.key)});
        try psi_prime.punish_set.put(culprit.key, {});
    }

    // Process faults
    const faults_span = span.child(@src(), .process_faults);
    defer faults_span.deinit();
    faults_span.debug("Processing {d} faults", .{extrinsic.faults.len});

    for (extrinsic.faults, 0..) |fault, i| {
        const fault_span = faults_span.child(@src(), .fault);
        defer fault_span.deinit();
        fault_span.debug("Processing fault {d} of {d}", .{ i + 1, extrinsic.faults.len });
        fault_span.trace("Public key: {s}", .{std.fmt.fmtSliceHexLower(&fault.key)});
        try psi_prime.punish_set.put(fault.key, {});
    }
}

fn countPositiveJudgments(verdict: Verdict) usize {
    var count: usize = 0;
    for (verdict.votes) |judgment| {
        if (judgment.vote) {
            count += 1;
        }
    }
    return count;
}

pub const VerificationError = error{
    AlreadyJudged,
    BadVoteSplit,
    VerdictsNotSortedUnique,
    JudgementsNotSortedUnique,
    CulpritsNotSortedUnique,
    FaultsNotSortedUnique,
    FaultKeyNotInValidatorSet,
    NotEnoughCulprits,
    NotEnoughFaults,
    CulpritsVerdictNotBad,
    FaultVerdictWrong,
    OffenderAlreadyReported,
    BadJudgementAge,
    BadValidatorIndex,
    BadValidatorPubKey,
    BadSignature,
};

fn verdictTargetHash(verdict: *const Verdict) Hash {
    return verdict.target;
}

fn culpritsKey(culprit: *const Culprit) types.Ed25519Public {
    return culprit.key;
}

fn faultKey(fault: *const Fault) types.Ed25519Public {
    return fault.key;
}

fn judgmentValidatorIndex(judgment: *const Judgment) u16 {
    return judgment.index;
}

fn verifyVerdictSignatures(
    verdict: Verdict,
    kappa: []const PublicKey,
    lambda: []const PublicKey,
    validator_count: usize,
    current_epoch: u32,
) VerificationError!void {
    for (verdict.votes) |judgment| {
        if (judgment.index >= validator_count) {
            return VerificationError.BadValidatorIndex;
        }

        const validator_key = if (verdict.age == current_epoch)
            kappa[judgment.index]
        else if (verdict.age == current_epoch - 1)
            lambda[judgment.index]
        else
            return VerificationError.BadJudgementAge;

        // ZIP-215 compliant verification
        const public_key = ed25519.PublicKey.fromBytes(validator_key);

        const message = if (judgment.vote)
            "jam_valid" ++ verdict.target
        else
            "jam_invalid" ++ verdict.target;

        const signature = ed25519.Signature.fromBytes(judgment.signature);

        signature.verify(message, public_key) catch {
            return VerificationError.BadSignature;
        };
    }
}

fn verifyCulpritSignatures(culprits: []const Culprit) VerificationError!void {
    for (culprits) |culprit| {
        // ZIP-215 compliant verification
        const public_key = ed25519.PublicKey.fromBytes(culprit.key);
        const message = "jam_guarantee" ++ culprit.target;
        const signature = ed25519.Signature.fromBytes(culprit.signature);

        signature.verify(message, public_key) catch {
            return VerificationError.BadSignature;
        };
    }
}

fn verifyFaultSignatures(faults: []const Fault) VerificationError!void {
    for (faults) |fault| {
        // ZIP-215 compliant verification
        const public_key = ed25519.PublicKey.fromBytes(fault.key);

        const message = if (fault.vote)
            "jam_valid" ++ fault.target
        else
            "jam_invalid" ++ fault.target;

        const signature = ed25519.Signature.fromBytes(fault.signature);

        signature.verify(message, public_key) catch {
            return VerificationError.BadSignature;
        };
    }
}

fn verifyVerdictRequirements(
    verdicts: []const Verdict,
    culprits: []const Culprit,
    faults: []const Fault,
    validator_count: usize,
) VerificationError!void {
    for (verdicts) |verdict| {
        const positive_votes = countPositiveJudgments(verdict);
        if (positive_votes == 0 and culprits.len < 2) {
            return VerificationError.NotEnoughCulprits;
        }
        if (positive_votes == validator_count * 2 / 3 + 1 and faults.len == 0) {
            return VerificationError.NotEnoughFaults;
        }
    }
}

pub fn verifyDisputesExtrinsicPre(
    extrinsic: DisputesExtrinsic,
    current_state: *const Psi,
    kappa: []const PublicKey,
    lambda: []const PublicKey,
    validator_count: usize,
    current_epoch: u32,
) VerificationError!void {
    // Safety assertions
    std.debug.assert(validator_count > 0);
    std.debug.assert(kappa.len == validator_count);
    std.debug.assert(lambda.len == validator_count);
    std.debug.assert(current_epoch >= 0);

    const span = trace.span(@src(), .verify_pre);
    defer span.deinit();
    span.debug("Starting pre-verification of disputes extrinsic", .{});
    span.debug("Validator count: {d}, Current epoch: {d}", .{ validator_count, current_epoch });
    span.debug("Verdicts: {d}, Culprits: {d}, Faults: {d}", .{
        extrinsic.verdicts.len,
        extrinsic.culprits.len,
        extrinsic.faults.len,
    });

    // Check if verdicts are sorted and unique
    try verifyOrderedUnique(
        extrinsic.verdicts,
        Verdict,
        Hash,
        verdictTargetHash,
        lessThanHash,
        VerificationError.VerdictsNotSortedUnique,
    );

    // Verify all signatures
    for (extrinsic.verdicts) |verdict| {
        try verifyVerdictSignatures(verdict, kappa, lambda, validator_count, current_epoch);
    }

    try verifyCulpritSignatures(extrinsic.culprits);
    try verifyFaultSignatures(extrinsic.faults);

    for (extrinsic.verdicts) |verdict| {

        // Check if the verdict has already been judged
        if (current_state.good_set.contains(verdict.target) or
            current_state.bad_set.contains(verdict.target) or
            current_state.wonky_set.contains(verdict.target))
        {
            return VerificationError.AlreadyJudged;
        }

        // Check if judgements are sorted and unique
        try verifyOrderedUnique(
            verdict.votes,
            Judgment,
            u16,
            judgmentValidatorIndex,
            lessThanU16,
            VerificationError.JudgementsNotSortedUnique,
        );

        // Verify vote split
        const positive_votes = countPositiveJudgments(verdict);
        if (positive_votes != validator_count * 2 / 3 + 1 and
            positive_votes != 0 and
            positive_votes != validator_count / 3)
        {
            return VerificationError.BadVoteSplit;
        }
    }

    // Check if culprits are sorted and unique
    try verifyOrderedUnique(
        extrinsic.culprits,
        Culprit,
        types.Ed25519Public,
        culpritsKey,
        lessThanPublicKey,
        VerificationError.CulpritsNotSortedUnique,
    );

    // Check if faults are sorted and unique
    try verifyOrderedUnique(
        extrinsic.faults,
        Fault,
        types.Ed25519Public,
        faultKey,
        lessThanPublicKey,
        VerificationError.FaultsNotSortedUnique,
    );

    // Check for enough culprits and faults
    try verifyVerdictRequirements(extrinsic.verdicts, extrinsic.culprits, extrinsic.faults, validator_count);

    // Verify culprits
    for (extrinsic.culprits) |culprit| {
        if (current_state.punish_set.contains(culprit.key)) {
            return VerificationError.OffenderAlreadyReported;
        }
    }

    // Verify faults
    for (extrinsic.faults) |fault| {
        if (current_state.punish_set.contains(fault.key)) {
            return VerificationError.OffenderAlreadyReported;
        }

        // check if the key is part of either the kappa or the lambda set
        // if (isKeyInSet(fault.key, kappa) or isKeyInSet(fault.key, lambda)) {
        //     return VerificationError.FaultKeyNotInValidatorSet;
        // }
    }
}

pub fn verifyDisputesExtrinsicPost(
    extrinsic: DisputesExtrinsic,
    posterior_state: *const Psi,
) VerificationError!void {
    const span = trace.span(@src(), .verify_post);
    defer span.deinit();
    span.debug("Starting post-verification of disputes extrinsic", .{});
    span.debug("Verdicts: {d}, Culprits: {d}, Faults: {d}", .{
        extrinsic.verdicts.len,
        extrinsic.culprits.len,
        extrinsic.faults.len,
    });

    // Verify culprits
    for (extrinsic.culprits) |culprit| {
        if (!posterior_state.bad_set.contains(culprit.target)) {
            return VerificationError.CulpritsVerdictNotBad;
        }
    }

    // Verify faults
    for (extrinsic.faults) |fault| {
        // Check if this after state transition this is correct
        const in_good_set = posterior_state.good_set.contains(fault.target);
        const in_bad_set = posterior_state.bad_set.contains(fault.target);
        if ((fault.vote and !in_bad_set) or (!fault.vote and !in_good_set)) {
            return VerificationError.FaultVerdictWrong;
        }
    }
}

fn isKeyInSet(key: PublicKey, set: []const PublicKey) bool {
    for (set) |pubKey| {
        if (std.mem.eql(u8, &key, &pubKey)) {
            return true;
        }
    }
    return false;
}

fn verifyOrderedUnique(
    items: anytype,
    comptime T: type,
    comptime U: type,
    mapFn: fn (*const T) U,
    compareFn: fn (U, U) std.math.Order,
    errortype: VerificationError,
) !void {
    const span = trace.span(@src(), .verify_ordered);
    defer span.deinit();
    span.debug("Verifying ordered uniqueness for {d} items", .{items.len});
    span.trace("Item type: {s}", .{@typeName(T)});

    if (items.len == 0) return;
    var prev = mapFn(&items[0]);
    for (items[1..]) |*item| {
        const map_item = mapFn(item);
        switch (compareFn(prev, map_item)) {
            .lt => {},
            .eq => return errortype,
            .gt => return errortype,
        }
        prev = map_item;
    }
}

fn lessThanHash(a: Hash, b: Hash) std.math.Order {
    return std.mem.order(u8, &a, &b);
}

fn lessThanPublicKey(a: PublicKey, b: PublicKey) std.math.Order {
    return std.mem.order(u8, &a, &b);
}

fn lessThanU16(a: u16, b: u16) std.math.Order {
    return std.math.order(a, b);
}
