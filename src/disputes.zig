const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;

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

pub const Psi = struct {
    good_set: std.AutoHashMap(Hash, void),
    bad_set: std.AutoHashMap(Hash, void),
    wonky_set: std.AutoHashMap(Hash, void),
    punish_set: std.AutoHashMap(PublicKey, void),

    pub fn init(allocator: Allocator) Psi {
        return Psi{
            .good_set = std.AutoHashMap(Hash, void).init(allocator),
            .bad_set = std.AutoHashMap(Hash, void).init(allocator),
            .wonky_set = std.AutoHashMap(Hash, void).init(allocator),
            .punish_set = std.AutoHashMap(PublicKey, void).init(allocator),
        };
    }

    pub fn clone(self: *const Psi) !Psi {
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
    }
};

// NOTE: We need to verify the signature of the judgements of the verdict, which
// is a signature of the validator (indicated by the validator index) public key,
// either in the kappa set if the age of the verdict is t/E, otherwise from the
// lambda set. We need to verify this one level up before this processDisputesExtrinsic
// is called. Maybe introduce a type VerifiedDisputesExtrinsic to ensure verification
// has been done using the type system. The signature is build as a concatenation of:
// jam_valid ++ verdict.target if voted true
// jam_invalid ++ verdict.target if voted false
//
// NOTE: The same for Culprit and Fault, where not validator index is given but the
// Edwards25519 public key of the validator. Which shoud be in the set of validators as
// defined above.
//
// NOTE: Ordering needs to be checked. Verdicts on target hash, culprits and faults signatures
// must be ordered by the key. The judgements need to be ordered by validator index
// and there must not be any duplicates.
//
// NOTE: The sizes need to be either two-

// TODO: Add a verify function for the DisputesExtrinsic which can report
// on an error as descibied in the test vectors:
// already_judged = 0,
// bad_vote_split = 1,
// verdicts_not_sorted_unique = 2,
// judgements_not_sorted_unique = 3,
// culprits_not_sorted_unique = 4,
// faults_not_sorted_unique = 5,
// not_enough_culprits = 6,
// not_enough_faults = 7,
// culprits_verdict_not_bad = 8,
// fault_verdict_wrong = 9,
// offender_already_reported = 10,
// bad_judgement_age = 11,
// bad_validator_index = 12,
// bad_signature = 13,

// The disputes extrinsic, ED , may contain one or more verdicts v as a
// compilation of judgments coming from exactly two-thirds plus one of either
// the active validator set or the previous epoch’s validator set, i.e. the
// Ed25519 keys of κ or λ.
pub fn processDisputesExtrinsic(current_state: *const Psi, extrinsic: DisputesExtrinsic, validator_count: usize) !Psi {
    var state = try current_state.clone();

    // Process verdicts: V Gp0.4.1 (107) (108)
    for (extrinsic.verdicts) |verdict| {
        const positive_judgments = countPositiveJudgments(verdict);
        if (positive_judgments == validator_count * 2 / 3 + 1) {
            try state.good_set.put(verdict.target, {});
        } else if (positive_judgments == 0) {
            try state.bad_set.put(verdict.target, {});
        } else if (positive_judgments == validator_count / 3) {
            try state.wonky_set.put(verdict.target, {});
        }
    }

    // The offender markers must contain exactly the keys
    // of all the new offenders.
    state.punish_set.clearRetainingCapacity();

    // Process culprits
    for (extrinsic.culprits) |culprit| {
        try state.punish_set.put(culprit.key, {});
    }

    // Process faults
    for (extrinsic.faults) |fault| {
        try state.punish_set.put(fault.key, {});
    }

    return state;
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

const testing = std.testing;

test "processDisputesExtrinsic - good set" {
    const allocator = std.testing.allocator;
    var current_state = Psi.init(allocator);
    defer current_state.deinit();

    const validator_count: usize = 3; // Simplified for testing
    const target_hash: Hash = [_]u8{1} ** 32;

    const extrinsic = types.DisputesExtrinsic{
        .verdicts = &[_]types.Verdict{.{
            .age = 0,
            .target = target_hash,
            .votes = &[_]types.Judgement{
                .{ .index = 0, .vote = true, .signature = [_]u8{0} ** 64 },
                .{ .index = 1, .vote = true, .signature = [_]u8{0} ** 64 },
                .{ .index = 2, .vote = true, .signature = [_]u8{0} ** 64 },
            },
        }},
        .culprits = &[_]types.Culprit{},
        .faults = &[_]types.Fault{},
    };

    var state = try processDisputesExtrinsic(&current_state, extrinsic, validator_count);
    defer state.deinit();

    try testing.expect(state.good_set.contains(target_hash));
    try testing.expect(!state.bad_set.contains(target_hash));
    try testing.expect(!state.wonky_set.contains(target_hash));
}

test "processDisputesExtrinsic - bad set" {
    const allocator = std.testing.allocator;
    var current_state = Psi.init(allocator);
    defer current_state.deinit();

    const validator_count: usize = 3; // Simplified for testing
    const target_hash: Hash = [_]u8{2} ** 32;

    const extrinsic = types.DisputesExtrinsic{
        .verdicts = &[_]types.Verdict{.{
            .age = 0,
            .target = target_hash,
            .votes = &[_]types.Judgement{
                .{ .index = 0, .vote = false, .signature = [_]u8{0} ** 64 },
                .{ .index = 1, .vote = false, .signature = [_]u8{0} ** 64 },
                .{ .index = 2, .vote = false, .signature = [_]u8{0} ** 64 },
            },
        }},
        .culprits = &[_]types.Culprit{},
        .faults = &[_]types.Fault{},
    };

    var state = try processDisputesExtrinsic(&current_state, extrinsic, validator_count);
    defer state.deinit();

    try testing.expect(!state.good_set.contains(target_hash));
    try testing.expect(state.bad_set.contains(target_hash));
    try testing.expect(!state.wonky_set.contains(target_hash));
}

test "processDisputesExtrinsic - wonky set" {
    const allocator = std.testing.allocator;
    var current_state = Psi.init(allocator);
    defer current_state.deinit();

    const validator_count: usize = 3; // Simplified for testing
    const target_hash: Hash = [_]u8{3} ** 32;

    const extrinsic = types.DisputesExtrinsic{
        .verdicts = &[_]types.Verdict{.{
            .age = 0,
            .target = target_hash,
            .votes = &[_]types.Judgement{
                .{ .index = 0, .vote = true, .signature = [_]u8{0} ** 64 },
                .{ .index = 1, .vote = false, .signature = [_]u8{0} ** 64 },
                .{ .index = 2, .vote = false, .signature = [_]u8{0} ** 64 },
            },
        }},
        .culprits = &[_]types.Culprit{},
        .faults = &[_]types.Fault{},
    };

    var state = try processDisputesExtrinsic(&current_state, extrinsic, validator_count);
    defer state.deinit();

    try testing.expect(!state.good_set.contains(target_hash));
    try testing.expect(!state.bad_set.contains(target_hash));
    try testing.expect(state.wonky_set.contains(target_hash));
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

fn culpritsKey(culprit: *const Culprit) types.Ed25519Key {
    return culprit.key;
}

fn faultKey(fault: *const Fault) types.Ed25519Key {
    return fault.key;
}

fn judgmentValidatorIndex(judgment: *const Judgment) u16 {
    return judgment.index;
}

pub fn verifyDisputesExtrinsicPre(
    extrinsic: DisputesExtrinsic,
    current_state: *const Psi,
    kappa: []const PublicKey,
    lambda: []const PublicKey,
    validator_count: usize,
    current_epoch: u32,
) VerificationError!void {
    // Check if verdicts are sorted and unique
    try verifyOrderedUnique(
        extrinsic.verdicts,
        Verdict,
        Hash,
        verdictTargetHash,
        lessThanHash,
        VerificationError.VerdictsNotSortedUnique,
    );

    for (extrinsic.verdicts) |verdict| {
        // Verify signatures
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

            const public_key = crypto.sign.Ed25519.PublicKey.fromBytes(validator_key) catch {
                return VerificationError.BadValidatorPubKey;
            };

            const message = if (judgment.vote)
                "jam_valid" ++ verdict.target
            else
                "jam_invalid" ++ verdict.target;

            const signature = crypto.sign.Ed25519.Signature.fromBytes(judgment.signature);

            signature.verify(message, public_key) catch {
                return VerificationError.BadSignature;
            };
        }

        // Check culprit signatures
        for (extrinsic.culprits) |culprit| {
            const public_key = crypto.sign.Ed25519.PublicKey.fromBytes(culprit.key) catch {
                return VerificationError.BadValidatorPubKey;
            };

            const message = "jam_guarantee" ++ culprit.target;

            const signature = crypto.sign.Ed25519.Signature.fromBytes(culprit.signature);

            signature.verify(message, public_key) catch {
                return VerificationError.BadSignature;
            };
        }

        // Check fault signatures
        for (extrinsic.faults) |fault| {
            const public_key = crypto.sign.Ed25519.PublicKey.fromBytes(fault.key) catch {
                return VerificationError.BadValidatorPubKey;
            };

            const message = if (fault.vote)
                "jam_valid" ++ fault.target
            else
                "jam_invalid" ++ fault.target;

            const signature = crypto.sign.Ed25519.Signature.fromBytes(fault.signature);

            signature.verify(message, public_key) catch {
                return VerificationError.BadSignature;
            };
        }

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
        types.Ed25519Key,
        culpritsKey,
        lessThanPublicKey,
        VerificationError.CulpritsNotSortedUnique,
    );

    // Check if faults are sorted and unique
    try verifyOrderedUnique(
        extrinsic.faults,
        Fault,
        types.Ed25519Key,
        faultKey,
        lessThanPublicKey,
        VerificationError.FaultsNotSortedUnique,
    );

    // Check for enough culprits and faults
    for (extrinsic.verdicts) |verdict| {
        const positive_votes = countPositiveJudgments(verdict);
        if (positive_votes == 0 and extrinsic.culprits.len < 2) {
            return VerificationError.NotEnoughCulprits;
        }
        if (positive_votes == validator_count * 2 / 3 + 1 and extrinsic.faults.len == 0) {
            return VerificationError.NotEnoughFaults;
        }
    }

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

// ... (rest of the code remains the same)
