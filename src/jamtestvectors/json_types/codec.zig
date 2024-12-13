const std = @import("std");
const hex = @import("hex_bytes.zig");

pub const HexBytes = hex.HexBytes;
pub const HexBytesFixed = hex.HexBytesFixed;

pub const U8 = u8;
pub const U16 = u16;
pub const U32 = u32;
pub const U64 = u64;
pub const ByteSequence = HexBytes;
pub const ByteArray32 = HexBytesFixed(32);

// Core hash types
pub const OpaqueHash = ByteArray32;
pub const HeaderHash = OpaqueHash;
pub const StateRoot = OpaqueHash;
pub const BeefyRoot = OpaqueHash;
pub const WorkPackageHash = OpaqueHash;
pub const WorkReportHash = OpaqueHash;
pub const ExportsRoot = OpaqueHash;
pub const ErasureRoot = OpaqueHash;

pub const TimeSlot = U32;
pub const ServiceId = U32;
pub const Gas = U64;
pub const ValidatorIndex = U16;
pub const CoreIndex = U16;
pub const TicketAttempt = u8; // as the range is 0..1

// Crypto types matching ASN
pub const BlsPublic = HexBytesFixed(144);
pub const BandersnatchPublic = ByteArray32;
pub const Ed25519Public = ByteArray32;
pub const BandersnatchVrfSignature = HexBytesFixed(96);
pub const BandersnatchRingVrfSignature = HexBytesFixed(784);
pub const Ed25519Signature = HexBytesFixed(64);

pub const Entropy = OpaqueHash;
pub const EntropyBuffer = [4]Entropy;

pub const ValidatorMetadata = HexBytesFixed(128);

pub const ServiceInfo = struct {
    code_hash: OpaqueHash,
    balance: U64,
    min_item_gas: Gas,
    min_memo_gas: Gas,
    bytes: U64,
    items: U32,
};

pub const RefineContext = struct {
    anchor: HeaderHash,
    state_root: StateRoot,
    beefy_root: BeefyRoot,
    lookup_anchor: HeaderHash,
    lookup_anchor_slot: TimeSlot,
    prerequisites: []OpaqueHash,
};

pub const ImportSpec = struct {
    tree_root: OpaqueHash,
    index: U16,
};

pub const ExtrinsicSpec = struct {
    hash: OpaqueHash,
    len: U32,
};

pub const Authorizer = struct {
    code_hash: OpaqueHash,
    params: HexBytes,
};

pub const ValidatorData = struct {
    bandersnatch: BandersnatchPublic,
    ed25519: Ed25519Public,
    bls: BlsPublic,
    metadata: ValidatorMetadata,
};

pub const WorkItem = struct {
    service: ServiceId,
    code_hash: OpaqueHash,
    payload: HexBytes,
    refine_gas_limit: Gas,
    accumulate_gas_limit: Gas,
    import_segments: []ImportSpec,
    extrinsic: []ExtrinsicSpec,
    export_count: U16,
};

pub const WorkPackage = struct {
    authorization: HexBytes,
    auth_code_host: ServiceId,
    authorizer: Authorizer,
    context: RefineContext,
    items: []WorkItem, // SIZE(1..4)
};

pub const WorkExecResult = union(enum(u8)) {
    ok: HexBytes = 0,
    out_of_gas: void = 1,
    panic: void = 2,
    bad_code: void = 3,
    code_oversize: void = 4,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: *std.json.Scanner,
        options: std.json.ParseOptions,
    ) std.json.ParseError(std.json.Scanner)!WorkExecResult {
        if (.object_begin != try source.next()) return error.UnexpectedToken;

        while (true) {
            const name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            _ = switch (name_token.?) {
                .string, .allocated_string => |slice| {
                    if (std.mem.eql(u8, slice, "ok")) {
                        const bytes = try std.json.innerParse(HexBytes, allocator, source, options);
                        if (.object_end != try source.next()) return error.UnexpectedToken;
                        return .{ .ok = bytes };
                    } else if (std.mem.eql(u8, slice, "out_of_gas")) {
                        _ = try source.next(); // ignore the null token
                        if (.object_end != try source.next()) return error.UnexpectedToken;
                        return .out_of_gas;
                    } else if (std.mem.eql(u8, slice, "panic")) {
                        _ = try source.next(); // ignore the null token
                        if (.object_end != try source.next()) return error.UnexpectedToken;
                        return .panic;
                    } else if (std.mem.eql(u8, slice, "bad_code")) {
                        _ = try source.next(); // ignore the null token
                        if (.object_end != try source.next()) return error.UnexpectedToken;
                        return .bad_code;
                    } else if (std.mem.eql(u8, slice, "code_oversize")) {
                        _ = try source.next(); // ignore the null token
                        if (.object_end != try source.next()) return error.UnexpectedToken;
                        return .code_oversize;
                    } else {
                        @panic("Unexpected field name");
                    }
                },
                .object_end => break,
                else => return error.UnexpectedToken,
            };
        }
        unreachable;
    }
};

pub const WorkResult = struct {
    service_id: ServiceId,
    code_hash: OpaqueHash,
    payload_hash: OpaqueHash,
    accumulate_gas: Gas,
    result: WorkExecResult,
};

pub const WorkPackageSpec = struct {
    hash: WorkPackageHash,
    length: U32,
    erasure_root: ErasureRoot,
    exports_root: ExportsRoot,
    exports_count: U16,
};

pub const SegmentRootLookupItem = struct {
    work_package_hash: WorkPackageHash,
    segment_tree_root: OpaqueHash,
};

pub const SegmentRootLookup = []SegmentRootLookupItem;

pub const WorkReport = struct {
    package_spec: WorkPackageSpec,
    context: RefineContext,
    core_index: CoreIndex,
    authorizer_hash: OpaqueHash,
    auth_output: HexBytes,
    segment_root_lookup: SegmentRootLookup,
    results: []WorkResult, // SIZE(1..4)
};

pub const MmrPeak = ?OpaqueHash;

pub const Mmr = struct {
    peaks: []MmrPeak,
};

pub const ReportedWorkPackage = struct {
    hash: WorkReportHash,
    exports_root: ExportsRoot,
};

pub const BlockInfo = struct {
    header_hash: HeaderHash,
    mmr: Mmr,
    state_root: StateRoot,
    reported: []ReportedWorkPackage,
};

pub const BlocksHistory = []BlockInfo; // SIZE(0..max_blocks_history)

pub const EpochMark = struct {
    entropy: Entropy,
    tickets_entropy: Entropy,
    validators: []BandersnatchPublic, // SIZE(validators_count)
};

pub const TicketBody = struct {
    id: OpaqueHash,
    attempt: TicketAttempt,
};

pub const TicketsMark = []TicketBody; // SIZE(epoch_length)

pub const Header = struct {
    parent: HeaderHash,
    parent_state_root: StateRoot,
    extrinsic_hash: OpaqueHash,
    slot: TimeSlot,
    epoch_mark: ?EpochMark = null,
    tickets_mark: ?TicketsMark = null,
    offenders_mark: []Ed25519Public,
    author_index: ValidatorIndex,
    entropy_source: BandersnatchVrfSignature,
    seal: BandersnatchVrfSignature,
};

pub const TicketEnvelope = struct {
    attempt: TicketAttempt,
    signature: BandersnatchRingVrfSignature,
};

pub const TicketsExtrinsic = []TicketEnvelope; // SIZE(0..16)

pub const Judgement = struct {
    vote: bool,
    index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const Verdict = struct {
    target: WorkReportHash,
    age: U32,
    votes: []Judgement, // SIZE(validators_super_majority)
};

pub const Culprit = struct {
    target: WorkReportHash,
    key: Ed25519Public,
    signature: Ed25519Signature,
};

pub const Fault = struct {
    target: WorkReportHash,
    vote: bool,
    key: Ed25519Public,
    signature: Ed25519Signature,
};

pub const DisputesExtrinsic = struct {
    verdicts: []Verdict,
    culprits: []Culprit,
    faults: []Fault,
};

pub const Preimage = struct {
    requester: ServiceId,
    blob: HexBytes,
};

pub const PreimagesExtrinsic = []Preimage;

pub const AvailAssurance = struct {
    anchor: OpaqueHash,
    bitfield: HexBytes, // SIZE(avail_bitfield_bytes)
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const AssurancesExtrinsic = []AvailAssurance; // SIZE(0..validators_count)

pub const ValidatorSignature = struct {
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const ReportGuarantee = struct {
    report: WorkReport,
    slot: TimeSlot,
    signatures: []ValidatorSignature,
};

pub const GuaranteesExtrinsic = []ReportGuarantee; // SIZE(0..cores_count)

pub const Extrinsic = struct {
    tickets: TicketsExtrinsic,
    disputes: DisputesExtrinsic,
    preimages: PreimagesExtrinsic,
    assurances: AssurancesExtrinsic,
    guarantees: GuaranteesExtrinsic,
};

pub const Block = struct {
    header: Header,
    extrinsic: Extrinsic,
};
