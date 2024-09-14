const std = @import("std");
const types = @import("types.zig");

pub const HexBytes = types.hex.HexBytes;
pub const HexBytesFixed = types.hex.HexBytesFixed;

pub const U8 = u8;
pub const U16 = u16;
pub const U32 = u32;
pub const U64 = u64;
pub const ByteSequence = HexBytes;
pub const ByteArray32 = HexBytesFixed(32);

pub const OpaqueHash = ByteArray32;
pub const TimeSlot = U32;
pub const ServiceId = U32;
pub const Gas = U64;
pub const ValidatorIndex = U16;
pub const CoreIndex = U16;
pub const TicketAttempt = u1; // as the range is 0..1

pub const BandersnatchKey = ByteArray32;
pub const Ed25519Key = ByteArray32;
pub const BandersnatchVrfSignature = HexBytesFixed(96);
pub const BandersnatchRingSignature = HexBytesFixed(784);
pub const Ed25519Signature = HexBytesFixed(64);

pub const RefineContext = struct {
    anchor: OpaqueHash,
    state_root: OpaqueHash,
    beefy_root: OpaqueHash,
    lookup_anchor: OpaqueHash,
    lookup_anchor_slot: TimeSlot,
    prerequisite: ?OpaqueHash = null,
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

pub const WorkItem = struct {
    service: ServiceId,
    code_hash: OpaqueHash,
    payload: HexBytes,
    gas_limit: Gas,
    import_segments: []ImportSpec,
    extrinsic: []ExtrinsicSpec,
    export_count: U16,
};

pub const WorkPackage = struct {
    authorization: HexBytes,
    auth_code_host: ServiceId,
    authorizer: Authorizer,
    context: RefineContext,
    items: []WorkItem, // max 4 workitems allowed
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
                .object_end => { // No more fields.
                    break;
                },
                else => {
                    return error.UnexpectedToken;
                },
            };
        }
        unreachable;
    }
};

pub const WorkResult = struct {
    service: ServiceId,
    code_hash: OpaqueHash,
    payload_hash: OpaqueHash,
    gas_ratio: Gas,
    result: WorkExecResult,
};

pub const WorkPackageSpec = struct {
    hash: OpaqueHash,
    len: U32,
    root: OpaqueHash,
    segments: OpaqueHash,
};

pub const WorkReport = struct {
    package_spec: WorkPackageSpec,
    context: RefineContext,
    core_index: CoreIndex,
    authorizer_hash: OpaqueHash,
    auth_output: HexBytes,
    results: []WorkResult, // max 4 allowed
};

pub const EpochMark = struct {
    entropy: OpaqueHash,
    validators: []BandersnatchKey, // validators-count size
};

pub const TicketBody = struct {
    id: OpaqueHash,
    attempt: TicketAttempt,
};

pub const TicketsMark = []TicketBody; // epoch-length

pub const Header = struct {
    parent: OpaqueHash,
    parent_state_root: OpaqueHash,
    extrinsic_hash: OpaqueHash,
    slot: TimeSlot,
    epoch_mark: ?EpochMark = null,
    tickets_mark: ?TicketsMark = null,
    offenders_mark: []Ed25519Key,
    author_index: ValidatorIndex,
    entropy_source: BandersnatchVrfSignature,
    seal: BandersnatchVrfSignature,
};

pub const TicketEnvelope = struct {
    attempt: TicketAttempt,
    signature: BandersnatchRingSignature,
};

pub const TicketsExtrinsic = []TicketEnvelope;

pub const Judgement = struct {
    vote: bool,
    index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const Verdict = struct {
    target: OpaqueHash,
    age: U32,
    votes: []Judgement, // validators_super_majority
};

pub const Culprit = struct {
    target: OpaqueHash,
    key: Ed25519Key,
    signature: Ed25519Signature,
};

pub const Fault = struct {
    target: OpaqueHash,
    vote: bool,
    key: Ed25519Key,
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
    bitfield: HexBytes, // avail_bitfield_bytes
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const AssurancesExtrinsic = []AvailAssurance; // validators_count

pub const ValidatorSignature = struct {
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const ReportGuarantee = struct {
    report: WorkReport,
    slot: TimeSlot,
    signatures: []ValidatorSignature,
};

pub const GuaranteesExtrinsic = []ReportGuarantee; // cores_count

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
