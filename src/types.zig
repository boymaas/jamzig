const std = @import("std");
const types = @import("types.zig");

pub const U8 = u8;
pub const U16 = u16;
pub const U32 = u32;
pub const U64 = u64;
pub const ByteSequence = []u8;
pub const ByteArray32 = [32]u8;

pub const OpaqueHash = ByteArray32;
pub const TimeSlot = U32;
pub const ServiceId = U32;
pub const Gas = U64;
pub const ValidatorIndex = U16;
pub const CoreIndex = U16;
pub const TicketAttempt = u1; // as the range is 0..1

pub const BandersnatchKey = ByteArray32;
pub const Ed25519Key = ByteArray32;
pub const BandersnatchVrfSignature = [96]u8;
pub const BandersnatchRingSignature = [784]u8;
pub const Ed25519Signature = [64]u8;

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
    params: []u8,
};

pub const WorkItem = struct {
    service: ServiceId,
    code_hash: OpaqueHash,
    payload: []u8,
    gas_limit: Gas,
    import_segments: []ImportSpec,
    extrinsic: []ExtrinsicSpec,
    export_count: U16,
};

pub const WorkPackage = struct {
    authorization: []u8,
    auth_code_host: ServiceId,
    authorizer: Authorizer,
    context: RefineContext,
    items: []WorkItem, // max 4 workitems allowed
};

pub const WorkExecResult = union(enum) {
    ok: []u8,
    out_of_gas: void,
    panic: void,
    bad_code: void,
    code_oversize: void,
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
    auth_output: []u8,
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

const TicketsMark = []TicketBody; // epoch-length

const CodecParams = struct {
    validators: usize,
    epoch_length: usize,
    cores_count: usize,

    // -- (validators-count * 2/3 + 1)
    validators_super_majority: usize,
    // -- (cores-count + 7) / 8
    avail_bitfield_bytes: usize,
};

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

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try @import("types/format.zig").formatHeader(self, writer);
    }
};

pub const TicketEnvelope = struct {
    attempt: TicketAttempt,
    signature: BandersnatchRingSignature,
};

const TicketsExtrinsic = []TicketEnvelope;

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
    blob: []u8,
};

const PreimagesExtrinsic = []Preimage;

pub const AvailAssurance = struct {
    anchor: OpaqueHash,
    bitfield: []u8, // avail_bitfield_bytes
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,
};

const AssurancesExtrinsic = []AvailAssurance; // validators_count

pub const ValidatorSignature = struct {
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const ReportGuarantee = struct {
    report: WorkReport,
    slot: TimeSlot,
    signatures: []ValidatorSignature,
};

const GuaranteesExtrinsic = []ReportGuarantee; // cores_count

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
