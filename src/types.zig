const std = @import("std");
const types = @import("types.zig");

pub const U8 = u8;
pub const U16 = u16;
pub const U32 = u32;
pub const U64 = u64;
pub const ByteSequence = []u8;
pub const ByteArray32 = [32]u8;

pub const OpaqueHash = ByteArray32;
pub const Hash = ByteArray32;
pub const TimeSlot = U32;
pub const ServiceId = U32;
pub const Gas = U64;
pub const ValidatorIndex = U16;
pub const CoreIndex = U16;
pub const TicketAttempt = u8; // as the range is 0..1

pub const Entropy = OpaqueHash;
pub const Eta = [4]Entropy;

pub const BlsKey = [144]u8;
pub const BandersnatchPrivateKey = ByteArray32;
pub const BandersnatchKey = ByteArray32;
pub const Ed25519Key = ByteArray32;
pub const BandersnatchVrfOutput = [32]u8;
pub const BandersnatchVrfSignature = [96]u8;
pub const BandersnatchVrfRoot = [144]u8;
pub const BandersnatchRingSignature = [784]u8;
pub const Ed25519Signature = [64]u8;

// We define the time in terms of seconds passed since the beginning of the Jam
// Common Era, 1200 UTC on January 1, 2024. Tau is the number of 6 second periods since
// the start of the Jam Common Era.
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

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .package_spec = self.package_spec,
            .context = self.context,
            .core_index = self.core_index,
            .authorizer_hash = self.authorizer_hash,
            .auth_output = try allocator.dupe(u8, self.auth_output),
            .results = try allocator.dupe(WorkResult, self.results),
        };
    }
};

pub const EpochMark = struct {
    entropy: Entropy,
    validators: []BandersnatchKey, // validators-count size

    // validator size is defined at runtime
    pub fn validators_size(params: CodecParams) usize {
        return params.validators;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .entropy = self.entropy,
            .validators = try allocator.dupe(BandersnatchKey, self.validators),
        };
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

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .tickets = try allocator.dupe(TicketBody, self.tickets),
        };
    }
};

// Safrole types
pub const Lambda = []ValidatorData;
pub const Kappa = []ValidatorData;
pub const GammaK = []ValidatorData;
pub const Iota = []ValidatorData;

// γₛ ∈ ⟦C⟧E ∪ ⟦HB⟧E
// the current epoch’s slot-sealer series, which is either a
// full complement of E tickets or, in the case of a fallback
// mode, a series of E Bandersnatch keys
pub const GammaS = union(enum) {
    tickets: []TicketBody,
    keys: []BandersnatchKey,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tickets => |tickets| {
                // We can use the Z_outsideInOrdering algorithm on tickets
                allocator.free(tickets);
            },
            // fallback
            .keys => |keys| {
                // We are in fallback mode
                allocator.free(keys);
            },
        }
    }
};

// γₐ ∈ ⟦C⟧∶E
// is the ticket accumulator, a series of highestscoring ticket identifiers to
// be used for the next epoch
pub const GammaA = []TicketBody;
pub const GammaZ = BandersnatchVrfRoot;

// Header
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
            .offenders_mark = try allocator.dupe(Ed25519Key, self.offenders_mark),
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

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .anchor = self.anchor,
            .bitfield = try allocator.dupe(u8, self.bitfield),
            .validator_index = self.validator_index,
            .signature = self.signature,
        };
    }

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

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .report = try self.report.deepClone(allocator),
            .slot = self.slot,
            .signatures = try allocator.dupe(ValidatorSignature, self.signatures),
        };
    }
};

/// 0..cores_count of ReportGuarantees
pub const GuaranteesExtrinsic = []ReportGuarantee; // cores_count

pub const Extrinsic = struct {
    tickets: TicketsExtrinsic,
    disputes: DisputesExtrinsic,
    preimages: PreimagesExtrinsic,
    assurances: AssurancesExtrinsic,
    guarantees: GuaranteesExtrinsic,

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

pub const CodecParams = struct {
    validators: usize,
    epoch_length: usize,
    cores_count: usize,

    // -- (validators-count * 2/3 + 1)
    validators_super_majority: usize,
    // -- (cores-count + 7) / 8
    avail_bitfield_bytes: usize,
};
