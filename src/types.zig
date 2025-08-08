const std = @import("std");
const types = @import("types.zig");
const jam_params = @import("jam_params.zig");

pub const fmt = @import("types/fmt.zig");

pub const U8 = u8;
pub const U16 = u16;
pub const U32 = u32;
pub const U64 = u64;
pub const ByteSequence = []u8;
pub const ByteArray32 = [32]u8;

// State dictionary key type (31 bytes per JAM 0.6.6)
pub const StateKey = [31]u8;

pub const OpaqueHash = ByteArray32;
pub const Hash = ByteArray32;
pub const Epoch = U32;
pub const TimeSlot = U32;
pub const ServiceId = U32;
pub const Gas = U64;
pub const Balance = U64;
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
pub const AccumulateRoot = OpaqueHash;
pub const AccumulateOutput = OpaqueHash;
pub const AuthorizerHash = OpaqueHash;

pub const Entropy = OpaqueHash;
pub const EntropyBuffer = [4]Entropy;
pub const Eta = EntropyBuffer;

pub const BlsPublic = [144]u8;
pub const BandersnatchPublic = ByteArray32;
pub const Ed25519Public = ByteArray32;
pub const BandersnatchVrfOutput = OpaqueHash;
pub const BandersnatchVrfRoot = BlsPublic; // TODO: check if this is correct
pub const BandersnatchVrfSignature = [96]u8;
pub const BandersnatchIetfVrfSignature = [96]u8;
pub const BandersnatchRingVrfSignature = [784]u8;
pub const BandersnatchRingCommitment = [144]u8;
pub const Ed25519Signature = [64]u8;

pub const BandersnatchKeyPair = struct {
    private_key: ByteArray32,
    public_key: BandersnatchPublic,
};

pub const ValidatorMetadata = [128]u8;

pub const ServiceInfo = struct {
    code_hash: OpaqueHash,
    balance: Balance,
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
    prerequisites: []WorkPackageHash,

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .anchor = self.anchor,
            .state_root = self.state_root,
            .beefy_root = self.beefy_root,
            .lookup_anchor = self.lookup_anchor,
            .lookup_anchor_slot = self.lookup_anchor_slot,
            .prerequisites = try allocator.dupe(OpaqueHash, self.prerequisites),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.prerequisites);
        self.* = undefined;
    }
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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.params);
        self.* = undefined;
    }
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
    payload: []u8,
    refine_gas_limit: Gas,
    accumulate_gas_limit: Gas,
    import_segments: []ImportSpec,
    extrinsic: []ExtrinsicSpec,
    export_count: U16,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.import_segments);
        allocator.free(self.extrinsic);
        self.* = undefined;
    }
};

pub const WorkPackage = struct {
    authorization: []u8,
    auth_code_host: ServiceId,
    authorizer: Authorizer,
    context: RefineContext,
    items: []WorkItem, // SIZE(1..4)

    /// Validates WorkPackage constraints according to JAM 0.6.6 specification
    pub fn validate(self: *const @This(), comptime params: @import("jam_params.zig").Params) !void {
        // WA: Authorization code size limit (64,000 octets)
        if (self.authorization.len > params.max_authorization_code_size) {
            return error.AuthorizationCodeTooLarge;
        }

        // I: Work items count constraint (1..4 in current implementation, 1..16 per spec)
        if (self.items.len == 0 or self.items.len > params.max_work_items_per_package) {
            return error.InvalidWorkItemsCount;
        }
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.authorization);
        self.authorizer.deinit(allocator);
        self.context.deinit(allocator);
        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Work execution result as defined in JAM graypaper
/// Corresponds to the error set J ∈ {∞, ⌊, ⊙, ⊖, BAD, BIG}
/// See graypaper sections:
/// - Definition: reporting_assurance.tex equation 98
/// - Serialization: serialization.tex equation 37 (function O)
/// - Usage: work_packages_and_reports.tex (countupexports function)
pub const WorkExecResult = union(enum(u8)) {
    /// Success with output data (corresponds to Y in graypaper)
    ok: []const u8 = 0,
    /// Out of gas error (∞)
    out_of_gas: void = 1,
    /// Panic error (⌊)
    panic: void = 2,
    /// Bad exports error (⊙)
    bad_exports: void = 3,
    /// Bad code error (BAD)
    bad_code: void = 4,
    /// Code oversize error (BIG)
    code_oversize: void = 5,

    /// length of result
    pub fn len(self: *const @This()) usize {
        switch (self.*) {
            .ok => |data| return data.len,
            else => return 0,
        }
    }

    // TODO: make a good type here
    pub fn getOutputHash(self: *const @This(), comptime H: type) !OpaqueHash {
        var hasher = H.init(.{});

        switch (self.*) {
            .ok => |data| hasher.update(data),
            else => {
                return error.OkTagNotActive;
            },
        }

        var hash: OpaqueHash = undefined;
        hasher.final(&hash);
        return hash;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return switch (self) {
            .ok => |data| WorkExecResult{ .ok = try allocator.dupe(u8, data) },
            else => self,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }

    pub fn encode(self: *const @This(), _: anytype, writer: anytype) !void {
        // First write the tag byte based on the union variant
        const tag: u8 = switch (self.*) {
            .ok => 0,
            .out_of_gas => 1,
            .panic => 2,
            .bad_exports => 3,
            .bad_code => 4,
            .code_oversize => 5,
        };
        try writer.writeByte(tag);

        // Write additional data for the ok variant only
        switch (self.*) {
            .ok => |data| {
                const codec = @import("codec.zig");
                try codec.writeInteger(@intCast(data.len), writer);
                try writer.writeAll(data);
            },
            else => {},
        }
    }

    pub fn decode(_: anytype, reader: anytype, alloc: std.mem.Allocator) !@This() {
        const tag = try reader.readByte();

        const tracing = comptime @import("tracing.zig").scoped(.codec);
        const span = tracing.span(.work_exec_result_decode);
        span.debug("Decoding WorkExecResult with tag: {d}", .{tag});

        return switch (tag) {
            0 => blk: {
                const codec = @import("codec.zig");
                const length = try codec.readInteger(reader);
                const data = try alloc.alloc(u8, length);

                try reader.readNoEof(data);

                span.debug("Reading WorkExecResult.ok with length: {d}", .{length});
                span.trace("Reading WorkExecResult.ok data: {s}", .{std.fmt.fmtSliceHexLower(data)});

                break :blk WorkExecResult{ .ok = data };
            },
            1 => WorkExecResult{ .out_of_gas = {} },
            2 => WorkExecResult{ .panic = {} },
            3 => WorkExecResult{ .bad_exports = {} },
            4 => WorkExecResult{ .bad_code = {} },
            5 => WorkExecResult{ .code_oversize = {} },
            else => error.InvalidTag,
        };
    }
};

pub const RefineLoad = struct {
    gas_used: U64,
    imports: U16,
    extrinsic_count: U16,
    extrinsic_size: U32,
    exports: U16,

    pub fn encode(self: *const @This(), _: anytype, writer: anytype) !void {
        const codec = @import("codec.zig");

        // Encode each field using variable-length integer encoding
        try codec.writeInteger(self.gas_used, writer);
        try codec.writeInteger(self.imports, writer);
        try codec.writeInteger(self.extrinsic_count, writer);
        try codec.writeInteger(self.extrinsic_size, writer);
        try codec.writeInteger(self.exports, writer);
    }

    pub fn decode(_: anytype, reader: anytype, _: std.mem.Allocator) !@This() {
        const codec = @import("codec.zig");

        // Read each field using variable-length integer decoding
        // and truncate to the appropriate size
        const gas_used = try codec.readInteger(reader);
        const imports = @as(U16, @truncate(try codec.readInteger(reader)));
        const extrinsic_count = @as(U16, @truncate(try codec.readInteger(reader)));
        const extrinsic_size = @as(U32, @truncate(try codec.readInteger(reader)));
        const exports = @as(U16, @truncate(try codec.readInteger(reader)));

        return @This(){
            .gas_used = gas_used,
            .imports = imports,
            .extrinsic_count = extrinsic_count,
            .extrinsic_size = extrinsic_size,
            .exports = exports,
        };
    }
};

pub const WorkResult = struct {
    service_id: ServiceId,
    code_hash: OpaqueHash,
    payload_hash: OpaqueHash,
    accumulate_gas: Gas,
    result: WorkExecResult,
    refine_load: RefineLoad,

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .service_id = self.service_id,
            .code_hash = self.code_hash,
            .payload_hash = self.payload_hash,
            .accumulate_gas = self.accumulate_gas,
            .result = try self.result.deepClone(allocator),
            .refine_load = self.refine_load,
        };
    }

    pub fn deinit(self: *WorkResult, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkPackageSpec = struct {
    hash: WorkPackageHash,
    length: U32,
    erasure_root: ErasureRoot,
    exports_root: ExportsRoot,
    exports_count: U16,
};

pub const AvailabilityAssignment = struct {
    report: WorkReport,
    timeout: U32,

    pub fn isTimedOut(self: @This(), work_replacement_period: u8, timeslot: TimeSlot) bool {
        return timeslot >= self.timeout + work_replacement_period;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.report.deinit(allocator);
        self.* = undefined;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .report = try self.report.deepClone(allocator),
            .timeout = self.timeout,
        };
    }
};

pub const AvailabilityAssignments = struct {
    items: []?AvailabilityAssignment,

    pub fn items_size(params: jam_params.Params) usize {
        return params.core_count;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items) |*assignment| {
            if (assignment.*) |*item| {
                item.report.deinit(allocator);
            }
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SegmentRootLookupItem = struct {
    work_package_hash: WorkPackageHash,
    segment_tree_root: OpaqueHash,
};

pub const SegmentRootLookup = []SegmentRootLookupItem;

// TODO: since these are varint encoded, I wrapped them, maybe adapt codec
// to create a special type indicating they are varint
pub const WorkReportStats = struct {
    auth_gas_used: Gas,

    pub fn encode(self: *const @This(), _: anytype, writer: anytype) !void {
        const codec = @import("codec.zig");

        try codec.writeInteger(self.auth_gas_used, writer);
    }

    pub fn decode(_: anytype, reader: anytype, _: std.mem.Allocator) !@This() {
        const codec = @import("codec.zig");

        const auth_gas_used = try codec.readInteger(reader);

        return .{
            .auth_gas_used = auth_gas_used,
        };
    }
};

pub const WorkReport = struct {
    package_spec: WorkPackageSpec,
    context: RefineContext,
    core_index: CoreIndex,
    authorizer_hash: OpaqueHash,
    auth_output: []u8,
    segment_root_lookup: SegmentRootLookup,
    results: []WorkResult, // SIZE(1..4)
    stats: WorkReportStats,

    pub fn totalAccumulateGas(self: *const @This()) types.Gas {
        var total: types.Gas = 0;
        for (self.results) |result| {
            total += result.accumulate_gas;
        }
        return total;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .package_spec = self.package_spec,
            .context = try self.context.deepClone(allocator),
            .core_index = self.core_index,
            .authorizer_hash = self.authorizer_hash,
            .auth_output = try allocator.dupe(u8, self.auth_output),
            .segment_root_lookup = try allocator.dupe(SegmentRootLookupItem, self.segment_root_lookup),
            .results = blk: {
                const cloned_results = try allocator.alloc(WorkResult, self.results.len);
                for (self.results, cloned_results) |result, *cloned| {
                    cloned.* = try result.deepClone(allocator);
                }
                break :blk cloned_results;
            },
            .stats = self.stats,
        };
    }

    pub fn deinit(self: *WorkReport, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        allocator.free(self.auth_output);
        allocator.free(self.segment_root_lookup);

        for (self.results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(self.results);
        self.* = undefined;
    }

    pub fn encode(self: *const @This(), comptime params: anytype, writer: anytype) !void {
        const codec = @import("codec.zig");

        // Encode each field in order
        try codec.serialize(@TypeOf(self.package_spec), params, writer, self.package_spec);
        try codec.serialize(@TypeOf(self.context), params, writer, self.context);

        // Variable encode the core_index
        try codec.writeInteger(self.core_index, writer);

        try codec.serialize(@TypeOf(self.authorizer_hash), params, writer, self.authorizer_hash);
        try codec.serialize(@TypeOf(self.auth_output), params, writer, self.auth_output);
        try codec.serialize(@TypeOf(self.segment_root_lookup), params, writer, self.segment_root_lookup);
        try codec.serialize(@TypeOf(self.results), params, writer, self.results);
        try codec.serialize(@TypeOf(self.stats), params, writer, self.stats);
    }

    pub fn decode(comptime params: anytype, reader: anytype, allocator: std.mem.Allocator) !@This() {
        const codec = @import("codec.zig");

        var self: @This() = undefined;

        // Decode each field in order
        self.package_spec = try codec.deserializeAlloc(WorkPackageSpec, params, allocator, reader);
        self.context = try codec.deserializeAlloc(RefineContext, params, allocator, reader);

        // Variable decode the core_index
        self.core_index = @as(CoreIndex, @truncate(try codec.readInteger(reader)));

        self.authorizer_hash = try codec.deserializeAlloc(@TypeOf(self.authorizer_hash), params, allocator, reader);
        self.auth_output = try codec.deserializeAlloc(@TypeOf(self.auth_output), params, allocator, reader);
        self.segment_root_lookup = try codec.deserializeAlloc(@TypeOf(self.segment_root_lookup), params, allocator, reader);
        self.results = try codec.deserializeAlloc(@TypeOf(self.results), params, allocator, reader);
        self.stats = try codec.deserializeAlloc(@TypeOf(self.stats), params, allocator, reader);

        return self;
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
    /// The hash of the block header
    header_hash: Hash,
    /// The Merkle Mountain Range (MMR) of BEEFY commitments
    beefy_mmr: []?Hash,
    /// The root hash of the state trie
    state_root: Hash,
    /// The hashes of work reports included in this block
    work_reports: []ReportedWorkPackage,

    pub fn beefyMmrRoot(self: *const @This()) Hash {
        return @import("merkle/mmr.zig").superPeak(self.beefy_mmr, std.crypto.hash.sha3.Keccak256);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.beefy_mmr);
        allocator.free(self.work_reports);
        self.* = undefined;
    }

    /// Creates a deep copy of the BlockInfo with newly allocated memory
    pub fn deepClone(self: *const BlockInfo, allocator: std.mem.Allocator) !BlockInfo {
        return BlockInfo{
            .header_hash = self.header_hash,
            .state_root = self.state_root,
            .beefy_mmr = try allocator.dupe(?Hash, self.beefy_mmr),
            .work_reports = try allocator.dupe(ReportedWorkPackage, self.work_reports),
        };
    }
};

pub const BlocksHistory = []BlockInfo; // SIZE(0..max_blocks_history)

pub const EpochMarkValidatorsKeys = struct {
    bandersnatch: BandersnatchPublic,
    ed25519: Ed25519Public,
};

pub const EpochMark = struct {
    entropy: Entropy,
    tickets_entropy: Entropy,
    validators: []EpochMarkValidatorsKeys, // SIZE(validators_count)

    pub fn validators_size(params: jam_params.Params) usize {
        return params.validators_count;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.validators);
        self.* = undefined;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .entropy = self.entropy,
            .tickets_entropy = self.tickets_entropy,
            .validators = try allocator.dupe(EpochMarkValidatorsKeys, self.validators),
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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.tickets);
        self.* = undefined;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .tickets = try allocator.dupe(TicketBody, self.tickets),
        };
    }
};

pub const ValidatorSet = struct {
    validators: []ValidatorData,

    const KeyType = enum {
        BlsPublic,
        BandersnatchPublic,
        Ed25519Public,
    };

    pub fn validators_size(params: jam_params.Params) usize {
        return params.validators_count;
    }

    /// Find the index of a validator by their public key
    /// key_type must be "bls", "bandersnatch", or "edwards"
    /// Returns error.ValidatorNotFound if the key doesn't match any validator
    pub fn findValidatorIndex(self: ValidatorSet, comptime key_type: KeyType, key: anytype) !u16 {
        const field_name = comptime switch (key_type) {
            .BlsPublic => "bls",
            .BandersnatchPublic => "bandersnatch",
            .Ed25519Public => "ed25519",
        };

        for (self.validators, 0..) |validator, i| {
            // std.debug.print("Comparing validator[{d}] key: {any} with search key: {any}\n", .{ i, &@field(validator, field_name), &key });
            if (std.mem.eql(u8, &@field(validator, field_name), &key)) {
                // std.debug.print("Found validator[{d}] with key: {any}\n", .{ i, &key });
                return @intCast(i);
            }
        }
        return error.ValidatorNotFound;
    }

    pub fn init(allocator: std.mem.Allocator, validators_count: u32) !@This() {
        return @This(){
            .validators = try allocator.alloc(ValidatorData, validators_count),
        };
    }

    /// Returns an allocated slice of BLS public keys from all validators
    pub fn getBlsPublicKeys(self: ValidatorSet, allocator: std.mem.Allocator) ![]BlsPublic {
        var keys = try allocator.alloc(BlsPublic, self.validators.len);
        for (self.validators, 0..) |validator, i| {
            keys[i] = validator.bls_key;
        }
        return keys;
    }

    /// Returns an allocated slice of Bandersnatch public keys from all validators
    pub fn getBandersnatchPublicKeys(self: ValidatorSet, allocator: std.mem.Allocator) ![]BandersnatchPublic {
        var keys = try allocator.alloc(BandersnatchPublic, self.validators.len);
        for (self.validators, 0..) |validator, i| {
            keys[i] = validator.bandersnatch;
        }
        return keys;
    }

    /// Returns an allocated slice of Bandersnatch public keys from all validators
    pub fn getEd25519PublicKeys(self: ValidatorSet, allocator: std.mem.Allocator) ![]BandersnatchPublic {
        var keys = try allocator.alloc(BandersnatchPublic, self.validators.len);
        for (self.validators, 0..) |validator, i| {
            keys[i] = validator.ed25519;
        }
        return keys;
    }

    /// Returns an allocated slice of EpochMarkValidatorsKeys from all validators
    pub fn getEpochMarkValidatorsKeys(self: ValidatorSet, allocator: std.mem.Allocator) ![]EpochMarkValidatorsKeys {
        var keys = try allocator.alloc(EpochMarkValidatorsKeys, self.validators.len);
        for (self.validators, 0..) |validator, i| {
            keys[i] = EpochMarkValidatorsKeys{
                .bandersnatch = validator.bandersnatch,
                .ed25519 = validator.ed25519,
            };
        }
        return keys;
    }

    pub fn clearAndTakeOwnership(self: *@This()) []ValidatorData {
        const current = self.validators;
        self.validators = &[_]ValidatorData{};
        return current;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.validators);
        self.* = undefined;
    }

    pub fn len(self: @This()) usize {
        return self.validators.len;
    }

    pub fn items(self: @This()) []ValidatorData {
        return self.validators;
    }

    pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .validators = try allocator.dupe(ValidatorData, self.validators),
        };
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

    pub fn tickets_size(params: jam_params.Params) usize {
        return params.epoch_length;
    }

    pub fn keys_size(params: jam_params.Params) usize {
        return params.epoch_length;
    }

    pub fn clearAndTakeOwnership(self: *@This()) @This() {
        const current = self.*;
        switch (self.*) {
            .tickets => |*tickets| tickets.* = &[_]TicketBody{},
            .keys => |*keys| keys.* = &[_]BandersnatchPublic{},
        }
        return current;
    }

    // TODO: make the const* to *
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tickets => |tickets| allocator.free(tickets),
            .keys => |keys| allocator.free(keys),
        }
        self.* = undefined;
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

// TODO: make into struct
pub const GammaA = []TicketBody;
pub const GammaZ = BlsPublic;

pub const OffendersMark = []Ed25519Public; // SIZE(0..validators_count)

pub const HeaderUnsigned = struct {
    parent: HeaderHash,
    parent_state_root: StateRoot,
    extrinsic_hash: OpaqueHash,
    slot: TimeSlot,
    epoch_mark: ?EpochMark = null,
    tickets_mark: ?TicketsMark = null,
    offenders_mark: []Ed25519Public,
    author_index: ValidatorIndex,
    entropy_source: BandersnatchVrfSignature,

    /// Creates HeaderUnsigned from Header, excluding the seal.
    /// Used for encoding to bytes without allocations. Shares
    /// ownership with the original header.
    pub fn fromHeaderShared(header: *const Header) @This() {
        return @This(){
            .parent = header.parent,
            .parent_state_root = header.parent_state_root,
            .extrinsic_hash = header.extrinsic_hash,
            .slot = header.slot,
            .epoch_mark = header.epoch_mark,
            .tickets_mark = header.tickets_mark,
            .offenders_mark = header.offenders_mark,
            .author_index = header.author_index,
            .entropy_source = header.entropy_source,
        };
    }
};

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

    // TODO: this should be cached on next call
    pub fn header_hash(
        self: @This(),
        comptime params: jam_params.Params,
        allocator: std.mem.Allocator,
    ) !HeaderHash {
        const codec = @import("codec.zig");
        // TODO: optimize we can remove allocation here as we can calculate
        // the max size of the header
        const header_with_seal = try codec.serializeAlloc(Header, params, allocator, self);
        defer allocator.free(header_with_seal);

        const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);
        var hash: [32]u8 = undefined;
        var hasher = Blake2b256.init(.{});
        hasher.update(header_with_seal);
        hasher.final(&hash);

        return hash;
    }

    pub fn getEntropy(self: *const @This()) !types.Entropy {
        return try @import("crypto/bandersnatch.zig")
            .Bandersnatch.Signature
            .fromBytes(self.entropy_source)
            .outputHash();
    }

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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.offenders_mark);
        if (self.epoch_mark) |*em| {
            em.deinit(allocator);
        }
        if (self.tickets_mark) |*tm| {
            tm.deinit(allocator);
        }
        self.* = undefined;
    }
};

pub const TicketEnvelope = struct {
    attempt: TicketAttempt,
    signature: BandersnatchRingVrfSignature,
};

pub const TicketsExtrinsic = struct {
    data: []TicketEnvelope, // SIZE(0..16)

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .data = try allocator.dupe(TicketEnvelope, self.data),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const Judgement = struct {
    vote: bool,
    index: ValidatorIndex,
    signature: Ed25519Signature,
};

pub const Verdict = struct {
    target: OpaqueHash,
    age: U32,
    votes: []const Judgement, // SIZE(validators_super_majority)

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.votes);
        self.* = undefined;
    }

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

pub const DisputesRecords = struct {
    // Good verdicts (psi_g)
    good: []WorkReportHash,
    // Bad verdicts (psi_b)
    bad: []WorkReportHash,
    // Wonky verdicts (psi_w)
    wonky: []WorkReportHash,
    // Offenders (psi_o)
    offenders: []Ed25519Public,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.good);
        allocator.free(self.bad);
        allocator.free(self.wonky);
        allocator.free(self.offenders);
        self.* = undefined;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .good = try allocator.dupe(WorkReportHash, self.good),
            .bad = try allocator.dupe(WorkReportHash, self.bad),
            .wonky = try allocator.dupe(WorkReportHash, self.wonky),
            .offenders = try allocator.dupe(Ed25519Public, self.offenders),
        };
    }
};

pub const DisputesExtrinsic = struct {
    verdicts: []Verdict,
    culprits: []Culprit,
    faults: []Fault,

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
        for (self.verdicts) |*verdict| {
            verdict.deinit(allocator);
        }
        allocator.free(self.verdicts);
        allocator.free(self.culprits);
        allocator.free(self.faults);
        self.* = undefined;
    }
};

pub const Preimage = struct {
    requester: ServiceId,
    blob: []u8,

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .requester = self.requester,
            .blob = try allocator.dupe(u8, self.blob),
        };
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.blob);
    }
};

pub const PreimagesExtrinsic = struct {
    data: []Preimage,

    /// Number of preimages
    pub fn count(self: *const @This()) u32 {
        return @intCast(self.data.len);
    }

    /// Calculates the total number of bytes (octets) across all preimages in this extrinsic
    pub fn calcOctetsAcrossPreimages(self: *const @This()) u32 {
        var total_bytes: u32 = 0;
        for (self.data) |preimage| {
            total_bytes += @intCast(preimage.blob.len);
        }
        return total_bytes;
    }

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        var cloned_data = try allocator.alloc(Preimage, self.data.len);
        errdefer allocator.free(cloned_data);

        for (self.data, 0..) |preimage, i| {
            cloned_data[i] = try preimage.deepClone(allocator);
        }

        return @This(){
            .data = cloned_data,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.data) |preimage| {
            preimage.deinit(allocator);
        }
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const AvailAssurance = struct {
    anchor: OpaqueHash,
    bitfield: []u8, // SIZE(avail_bitfield_bytes)
    validator_index: ValidatorIndex,
    signature: Ed25519Signature,

    pub fn coreSetInBitfield(self: *const @This(), core: types.CoreIndex) bool {
        const byte = core / 8;
        const bit = core % 8;

        return self.bitfield[byte] & (@as(u8, 1) << @intCast(bit)) != 0;
    }

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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.bitfield);
        self.* = undefined;
    }
};

pub const AssurancesExtrinsic = struct {
    data: []AvailAssurance, // SIZE(0..validators_count)

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        var cloned_data = try allocator.alloc(AvailAssurance, self.data.len);
        // FIXME: in case of error below we need to run through and dealloc each allocated
        // item
        errdefer allocator.free(cloned_data);

        for (self.data, 0..) |assurance, i| {
            cloned_data[i] = try assurance.deepClone(allocator);
        }

        return @This(){
            .data = cloned_data,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.data) |*assurance| {
            assurance.deinit(allocator);
        }
        allocator.free(self.data);
        self.* = undefined;
    }
};

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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.report.deinit(allocator);
        allocator.free(self.signatures);
        self.* = undefined;
    }
};

pub const GuaranteesExtrinsic = struct {
    // TODO: rename to items
    data: []ReportGuarantee, // SIZE(0..cores_count)

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        var cloned_data = try allocator.alloc(ReportGuarantee, self.data.len);
        errdefer allocator.free(cloned_data);

        for (self.data, 0..) |guarantee, i| {
            // FIXME: in case of errors we need to deallocate what was allocated
            cloned_data[i] = try guarantee.deepClone(allocator);
        }

        return @This(){
            .data = cloned_data,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.data) |*assurance| {
            assurance.deinit(allocator);
        }
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const Extrinsic = struct {
    tickets: TicketsExtrinsic,
    preimages: PreimagesExtrinsic,
    guarantees: GuaranteesExtrinsic,
    assurances: AssurancesExtrinsic,
    disputes: DisputesExtrinsic,

    pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return @This(){
            .tickets = try self.tickets.deepClone(allocator),
            .disputes = try self.disputes.deepClone(allocator),
            .preimages = try self.preimages.deepClone(allocator),
            .assurances = try self.assurances.deepClone(allocator),
            .guarantees = try self.guarantees.deepClone(allocator),
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.tickets.deinit(allocator);
        self.preimages.deinit(allocator);
        self.assurances.deinit(allocator);
        self.guarantees.deinit(allocator);
        self.disputes.deinit(allocator);
        self.* = undefined;
    }

    /// Calculate the Blake2b256 hash of this extrinsic
    /// Formula: Hx = H(E(H^#(a))) where a is the array of extrinsic components
    /// and H^# means hash each element individually
    pub fn calculateHash(
        self: @This(),
        comptime params: jam_params.Params,
        allocator: std.mem.Allocator,
    ) !OpaqueHash {
        const codec = @import("codec.zig");
        const Blake2b256 = std.crypto.hash.blake2.Blake2b(256);

        // According to graypaper equations 5.4-5.6:
        // Hx ≡ H(E(H#(a)))
        // where a = [ET(ET), EP(EP), g, EA(EA), ED(ED)]
        // and g = E(↕[(H(w), E4(t), ↕a) | (w, t, a) −< EG])

        // Step 1: Encode each component using their specific encoding functions

        // ET(ET) - tickets encoding
        const tickets_encoded = try codec.serializeAlloc(TicketsExtrinsic, params, allocator, self.tickets);
        defer allocator.free(tickets_encoded);

        // EP(EP) - preimages encoding
        const preimages_encoded = try codec.serializeAlloc(PreimagesExtrinsic, params, allocator, self.preimages);
        defer allocator.free(preimages_encoded);

        // g = E(↕[(H(w), E4(t), ↕a) | (w, t, a) −< EG]) - guarantees special encoding
        const guarantees_encoded = blk: {
            // Create the list of tuples (H(w), E4(t), ↕a) for each guarantee
            var guarantee_tuples = try allocator.alloc([]const u8, self.guarantees.data.len);
            defer {
                for (guarantee_tuples) |tuple_bytes| {
                    allocator.free(tuple_bytes);
                }
                allocator.free(guarantee_tuples);
            }

            for (self.guarantees.data, 0..) |guarantee, i| {
                // Create tuple (H(w), E4(t), ↕a)
                var tuple_buffer = std.ArrayList(u8).init(allocator);
                defer tuple_buffer.deinit();

                // H(w) - hash of the work report
                const work_report_encoded = try codec.serializeAlloc(WorkReport, params, allocator, guarantee.report);
                defer allocator.free(work_report_encoded);

                var work_report_hash: OpaqueHash = undefined;
                Blake2b256.hash(work_report_encoded, &work_report_hash, .{});

                // E4(t) - slot encoded as 4 bytes little-endian
                var slot_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &slot_bytes, guarantee.slot, .little);

                // ↕a - signatures with length prefix
                const signatures_encoded = try codec.serializeAlloc([]ValidatorSignature, params, allocator, guarantee.signatures);
                defer allocator.free(signatures_encoded);

                // Build the tuple by encoding (hash, slot_bytes, signatures)
                // This should be encoded as a proper tuple, not just concatenated
                const tuple_writer = tuple_buffer.writer();
                try codec.serialize([32]u8, params, tuple_writer, work_report_hash);
                try tuple_writer.writeAll(&slot_bytes);
                try tuple_writer.writeAll(signatures_encoded);

                guarantee_tuples[i] = try tuple_buffer.toOwnedSlice();
            }

            // Now encode the list of tuples with length prefix: E(↕[...])
            var guarantees_list_buffer = std.ArrayList(u8).init(allocator);
            defer guarantees_list_buffer.deinit();

            const guarantees_writer = guarantees_list_buffer.writer();

            // Write length prefix
            try codec.writeInteger(guarantee_tuples.len, guarantees_writer);

            // Write each tuple
            for (guarantee_tuples) |tuple_bytes| {
                try guarantees_writer.writeAll(tuple_bytes);
            }

            break :blk try guarantees_list_buffer.toOwnedSlice();
        };
        defer allocator.free(guarantees_encoded);

        // EA(EA) - assurances encoding
        const assurances_encoded = try codec.serializeAlloc(AssurancesExtrinsic, params, allocator, self.assurances);
        defer allocator.free(assurances_encoded);

        // ED(ED) - disputes encoding
        const disputes_encoded = try codec.serializeAlloc(DisputesExtrinsic, params, allocator, self.disputes);
        defer allocator.free(disputes_encoded);

        // Step 2: Hash each encoded component (H#(a))
        var component_hashes: [5]OpaqueHash = undefined;
        Blake2b256.hash(tickets_encoded, &component_hashes[0], .{});
        Blake2b256.hash(preimages_encoded, &component_hashes[1], .{});
        Blake2b256.hash(guarantees_encoded, &component_hashes[2], .{});
        Blake2b256.hash(assurances_encoded, &component_hashes[3], .{});
        Blake2b256.hash(disputes_encoded, &component_hashes[4], .{});

        // Step 3: Encode the array of hashes E(H#(a))
        const hashes_encoded = try codec.serializeAlloc([5]OpaqueHash, params, allocator, component_hashes);
        defer allocator.free(hashes_encoded);

        // Step 4: Final hash H(E(H#(a)))
        var final_hash: OpaqueHash = undefined;
        Blake2b256.hash(hashes_encoded, &final_hash, .{});

        return final_hash;
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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        self.extrinsic.deinit(allocator);
        self.* = undefined;
    }
};
