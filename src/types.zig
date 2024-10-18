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
pub const TicketAttempt = u8; // as the range is 0..1

pub const Entropy = OpaqueHash;

pub const BlsKey = [144]u8;
pub const BandersnatchPrivateKey = ByteArray32;
pub const BandersnatchKey = ByteArray32;
pub const Ed25519Key = ByteArray32;
pub const BandersnatchVrfOutput = [32]u8;
pub const BandersnatchVrfSignature = [96]u8;
pub const BandersnatchVrfRoot = [144]u8;
pub const BandersnatchRingSignature = [784]u8;
pub const Ed25519Signature = [64]u8;

pub const Tau = u32;
pub const Epoch = u32;

pub const BandersnatchKeyPair = struct {
    private_key: BandersnatchPrivateKey,
    public_key: BandersnatchKey,
};

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

pub const ValidatorData = struct {
    bandersnatch: BandersnatchKey,
    ed25519: Ed25519Key,
    bls: BlsKey,
    metadata: [128]u8,
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
    // TODO: check this
    items: []WorkItem, // max 4 workitems allowed
};

pub const WorkExecResult = union(enum(u8)) {
    ok: []u8 = 0,
    out_of_gas: void = 1,
    panic: void = 2,
    bad_code: void = 3,
    code_oversize: void = 4,
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
    // TODO: check this
    results: []WorkResult, // max 4 allowed
};

pub const EpochMark = struct {
    entropy: Entropy,
    validators: []BandersnatchKey, // validators-count size

    // validator size is defined at runtime
    pub fn validators_size(params: CodecParams) usize {
        return params.validators;
    }
};

pub const TicketBody = struct {
    id: OpaqueHash,
    attempt: TicketAttempt,
};

pub const TicketsMark = struct {
    tickets: []TicketBody, // epoch-length

    // epoch length is defined at runtime
    pub fn tickets_size(params: CodecParams) usize {
        return params.epoch_length;
    }
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

pub const TicketsExtrinsic = []TicketEnvelope;

pub const Judgement = struct {
    vote: bool,
    index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const WorkReportHash = OpaqueHash;

pub const Verdict = struct {
    target: WorkReportHash,
    age: U32,
    votes: []const Judgement, // validators_super_majority

    // validators_super_majority size is defined at runtime
    pub fn votes_size(params: CodecParams) usize {
        return params.validators_super_majority;
    }
};

pub const Culprit = struct {
    target: WorkReportHash,
    key: Ed25519Key,
    signature: Ed25519Signature,
};

pub const Fault = struct {
    target: WorkReportHash,
    vote: bool,
    key: Ed25519Key,
    signature: Ed25519Signature,
};

pub const DisputesExtrinsic = struct {
    verdicts: []const Verdict,
    culprits: []const Culprit,
    faults: []const Fault,

    pub fn deinit(
        self: *DisputesExtrinsic,
        allocator: std.mem.Allocator,
    ) void {
        for (self.verdicts) |verdict| {
            allocator.free(verdict.votes);
        }
        allocator.free(self.verdicts);
        allocator.free(self.culprits);
        allocator.free(self.faults);
    }
};

pub const Preimage = struct {
    requester: ServiceId,
    blob: []u8,
};

pub const PreimagesExtrinsic = []Preimage;

pub const AvailAssurance = struct {
    anchor: OpaqueHash,
    bitfield: []u8, // avail_bitfield_bytes
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,

    pub fn bitfield_size(params: CodecParams) usize {
        return params.avail_bitfield_bytes;
    }
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

/// 0..cores_count of ReportGuarantees
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

pub const CodecParams = struct {
    validators: usize,
    epoch_length: usize,
    cores_count: usize,

    // -- (validators-count * 2/3 + 1)
    validators_super_majority: usize,
    // -- (cores-count + 7) / 8
    avail_bitfield_bytes: usize,
};
