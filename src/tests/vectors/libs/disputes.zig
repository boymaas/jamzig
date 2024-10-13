const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const HexBytesFixed = types.hex.HexBytesFixed;

pub const WorkReportHash = HexBytesFixed(32);

pub const EpochIndex = u32;
pub const TimeSlot = u32;

pub const Ed25519Key = HexBytesFixed(32);
pub const Ed25519Signature = HexBytesFixed(64);

pub const BlsKey = HexBytesFixed(144);
pub const BandersnatchKey = HexBytesFixed(32);

pub const AvailabilityAssignment = struct {
    dummy_work_report: HexBytesFixed(353),
    timeout: u32,
};

pub const AvailabilityAssignmentItem = union(enum) {
    none: void,
    some: AvailabilityAssignment,
};

pub const AvailabilityAssignments = []?AvailabilityAssignment;

pub const DisputeJudgement = struct {
    vote: bool,
    index: u16,
    signature: Ed25519Signature,
};

pub const DisputeVerdict = struct {
    target: WorkReportHash,
    age: EpochIndex,
    votes: []DisputeJudgement,
};

pub const DisputeCulpritProof = struct {
    target: WorkReportHash,
    key: Ed25519Key,
    signature: Ed25519Signature,
};

pub const DisputeFaultProof = struct {
    target: WorkReportHash,
    vote: bool,
    key: Ed25519Key,
    signature: Ed25519Signature,
};

pub const DisputesXt = struct {
    verdicts: []DisputeVerdict,
    culprits: []DisputeCulpritProof,
    faults: []DisputeFaultProof,
};

pub const DisputesOutputMarks = struct {
    offenders_mark: []Ed25519Key,
};

pub const DisputesRecords = struct {
    psi_g: []WorkReportHash,
    psi_b: []WorkReportHash,
    psi_w: []WorkReportHash,
    psi_o: []Ed25519Key,
};

pub const ValidatorData = struct {
    bandersnatch: BandersnatchKey,
    ed25519: Ed25519Key,
    bls: BlsKey,
    metadata: HexBytesFixed(128),
};

pub const ValidatorsData = []ValidatorData;

pub const State = struct {
    psi: DisputesRecords,
    rho: AvailabilityAssignments,
    tau: TimeSlot,
    kappa: ValidatorsData,
    lambda: ValidatorsData,
};

pub const Input = struct {
    disputes: DisputesXt,
};

pub const ErrorCode = enum(u8) {
    already_judged = 0,
    bad_vote_split = 1,
    verdicts_not_sorted_unique = 2,
    judgements_not_sorted_unique = 3,
    culprits_not_sorted_unique = 4,
    faults_not_sorted_unique = 5,
    not_enough_culprits = 6,
    not_enough_faults = 7,
    culprits_verdict_not_bad = 8,
    fault_verdict_wrong = 9,
    offender_already_reported = 10,
    bad_judgement_age = 11,
    bad_validator_index = 12,
    bad_signature = 13,
};

pub const Output = union(enum) {
    ok: DisputesOutputMarks,
    err: ErrorCode,
};

pub const TestCase = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,
};

pub const TestVector = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(
        allocator: Allocator,
        file_path: []const u8,
    ) !json.Parsed(TestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const json_buffer = try file.readToEndAlloc(allocator, 5 * 1024 * 1024);
        defer allocator.free(json_buffer);

        // configure json scanner to track diagnostics for easier debugging
        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, json_buffer);
        scanner.enableDiagnostics(&diagnostics);
        defer scanner.deinit();

        // parse from tokensource using the scanner
        return std.json.parseFromTokenSource(
            TestVector,
            allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .parse_numbers = false,
            },
        ) catch |err| {
            std.debug.print("Could not parse TestVector[{s}]: {}\n{any}", .{ file_path, err, diagnostics });
            return err;
        };
    }
};
