const std = @import("std");
const types = @import("types.zig");
const jam_params = @import("jam_params.zig");

pub const U8 = u8;
pub const U16 = u16;
pub const U32 = u32;
pub const U64 = u64;
pub const ByteSequence = []u8;
pub const ByteArray32 = [32]u8;

pub const OpaqueHash = ByteArray32;
pub const Hash = ByteArray32;
pub const Epoch = U32;
pub const TimeSlot = U32;
pub const ServiceId = U32;
pub const Gas = U64;
pub const ValidatorIndex = U16;
pub const CoreIndex = U16;
pub const TicketAttempt = u8;

// Specific hash types
pub const HeaderHash = OpaqueHash;
pub const StateRoot = OpaqueHash;
pub const BeefyRoot = OpaqueHash;
pub const WorkPackageHash = OpaqueHash;
pub const WorkReportHash = OpaqueHash;
pub const ExportsRoot = OpaqueHash;
pub const ErasureRoot = OpaqueHash;

pub const Entropy = OpaqueHash;
pub const EntropyBuffer = [4]Entropy;
pub const Eta = EntropyBuffer;

pub const BlsPublic = [144]u8;
pub const BandersnatchPublic = ByteArray32;
pub const Ed25519Public = ByteArray32;
pub const BandersnatchVrfOutput = OpaqueHash;
pub const BandersnatchVrfRoot = BlsPublic; // TODO: check if this is correct
pub const BandersnatchVrfSignature = [96]u8;
pub const BandersnatchRingVrfSignature = [784]u8;
pub const Ed25519Signature = [64]u8;

pub const BandersnatchKeyPair = struct {
    private_key: ByteArray32,
    public_key: BandersnatchPublic,
};

pub const ValidatorMetadata = [128]u8;

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
    params: []u8,
};

pub const ValidatorData = struct {
    bandersnatch: BandersnatchPublic,
    ed25519: Ed25519Public,
    bls: BlsPublic,
    metadata: ValidatorMetadata,

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try @import("state_json/types.zig").jsonStringify(self, jw);
    }
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
    items: []WorkItem, // SIZE(1..4)
};

pub const WorkExecResult = union(enum(u8)) {
    ok: []u8 = 0,
    out_of_gas: void = 1,
    panic: void = 2,
    bad_code: void = 3,
    code_oversize: void = 4,
};

pub const WorkResult = struct {
    service_id: ServiceId,
    code_hash: OpaqueHash,
    payload_hash: OpaqueHash,
    gas: Gas,
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
    auth_output: []u8,
    segment_root_lookup: SegmentRootLookup,
    results: []WorkResult, // SIZE(1..4)

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .package_spec = self.package_spec,
            .context = self.context,
            .core_index = self.core_index,
            .authorizer_hash = self.authorizer_hash,
            .auth_output = try allocator.dupe(u8, self.auth_output),
            .segment_root_lookup = try allocator.dupe(SegmentRootLookupItem, self.segment_root_lookup),
            .results = try allocator.dupe(WorkResult, self.results),
        };
    }
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

    pub fn validators_size(params: jam_params.Params) usize {
        return params.validators_count;
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.validators);
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .entropy = self.entropy,
            .tickets_entropy = self.tickets_entropy,
            .validators = try allocator.dupe(BandersnatchPublic, self.validators),
        };
    }
};

pub const TicketBody = struct {
    id: OpaqueHash,
    attempt: TicketAttempt,
};

pub const TicketsMark = struct {
    tickets: []TicketBody, // SIZE(epoch_length)

    pub fn tickets_size(params: jam_params.Params) usize {
        return params.epoch_length;
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.tickets);
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .tickets = try allocator.dupe(TicketBody, self.tickets),
        };
    }
};

pub const ValidatorSet = struct {
    validators: []ValidatorData,

    pub fn init(allocator: std.mem.Allocator, validators_count: u32) !@This() {
        return @This(){
            .validators = try allocator.alloc(ValidatorData, validators_count),
        };
    }

    pub fn len(self: @This()) usize {
        return self.validators.len;
    }

    pub fn items(self: @This()) []ValidatorData {
        return self.validators;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .validators = try allocator.dupe(ValidatorData, self.validators),
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.validators);
    }

    pub fn merge(self: *@This(), other: @This()) !void {
        if (self.validators.len != other.validators.len) {
            return error.LengthMismatch;
        }
        @memcpy(self.validators, other.validators);
    }
};

// Safrole types
pub const Lambda = ValidatorSet;
pub const Kappa = ValidatorSet;
pub const GammaK = ValidatorSet;
pub const Iota = ValidatorSet;

pub const GammaS = union(enum) {
    tickets: []TicketBody,
    keys: []BandersnatchPublic,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tickets => |tickets| allocator.free(tickets),
            .keys => |keys| allocator.free(keys),
        }
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return switch (self) {
            .tickets => |tickets| @This(){
                .tickets = try allocator.dupe(TicketBody, tickets),
            },
            .keys => |keys| @This(){
                .keys = try allocator.dupe(BandersnatchPublic, keys),
            },
        };
    }
};

pub const GammaA = []TicketBody;
pub const GammaZ = BlsPublic;

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

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        const epoch_mark = if (self.epoch_mark) |mark| try mark.deepClone(allocator) else null;
        const tickets_mark = if (self.tickets_mark) |mark| try mark.deepClone(allocator) else null;

        return @This(){
            .parent = self.parent,
            .parent_state_root = self.parent_state_root,
            .extrinsic_hash = self.extrinsic_hash,
            .slot = self.slot,
            .epoch_mark = epoch_mark,
            .tickets_mark = tickets_mark,
            .offenders_mark = try allocator.dupe(Ed25519Public, self.offenders_mark),
            .author_index = self.author_index,
            .entropy_source = self.entropy_source,
            .seal = self.seal,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try @import("types/format.zig").formatHeader(self, writer);
    }
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
    target: OpaqueHash,
    age: U32,
    votes: []const Judgement, // SIZE(validators_super_majority)

    pub fn votes_size(params: jam_params.Params) usize {
        return params.validators_super_majority;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .target = self.target,
            .age = self.age,
            .votes = try allocator.dupe(Judgement, self.votes),
        };
    }
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
    verdicts: []const Verdict,
    culprits: []const Culprit,
    faults: []const Fault,

    pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
        var verdicts = try allocator.alloc(Verdict, self.verdicts.len);
        for (self.verdicts, 0..) |verdict, i| {
            verdicts[i] = try verdict.deepClone(allocator);
        }

        return @This(){
            .verdicts = verdicts,
            .culprits = try allocator.dupe(Culprit, self.culprits),
            .faults = try allocator.dupe(Fault, self.faults),
        };
    }

    pub fn deinit(self: *DisputesExtrinsic, allocator: std.mem.Allocator) void {
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
    bitfield: []u8, // SIZE(avail_bitfield_bytes)
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .anchor = self.anchor,
            .bitfield = try allocator.dupe(u8, self.bitfield),
            .validator_index = self.validator_index,
            .signature = self.signature,
        };
    }

    pub fn bitfield_size(params: jam_params.Params) usize {
        return params.avail_bitfield_bytes;
    }
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

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .report = try self.report.deepClone(allocator),
            .slot = self.slot,
            .signatures = try allocator.dupe(ValidatorSignature, self.signatures),
        };
    }
};

pub const GuaranteesExtrinsic = []ReportGuarantee; // SIZE(0..cores_count)

pub const Extrinsic = struct {
    tickets: TicketsExtrinsic,
    preimages: PreimagesExtrinsic,
    guarantees: GuaranteesExtrinsic,
    assurances: AssurancesExtrinsic,
    disputes: DisputesExtrinsic,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try @import("types/format.zig").formatExtrinsic(self, writer);
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .tickets = try allocator.dupe(TicketEnvelope, self.tickets),
            .disputes = try self.disputes.deepClone(allocator),
            .preimages = try allocator.dupe(Preimage, self.preimages),
            .assurances = blk: {
                var assurances = try allocator.alloc(AvailAssurance, self.assurances.len);
                for (self.assurances, 0..) |assurance, i| {
                    assurances[i] = try assurance.deepClone(allocator);
                }
                break :blk assurances;
            },
            .guarantees = try allocator.dupe(ReportGuarantee, self.guarantees),
        };
    }
};

pub const Block = struct {
    header: Header,
    extrinsic: Extrinsic,

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .header = try self.header.deepClone(allocator),
            .extrinsic = try self.extrinsic.deepClone(allocator),
        };
    }
};
