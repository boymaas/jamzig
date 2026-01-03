const std = @import("std");
const time = @import("time.zig");
const tfmt = @import("types/fmt.zig");

/// Protocol parameters used throughout the JAM system.
/// Each field represents a specific constant from the graypaper specification.
/// The constants are annotated with their corresponding symbols (e.g., E, N, K).
/// These parameters control various aspects of consensus, validation, storage,
/// and execution within the protocol.
pub const Params = struct {
    // ===== Core Protocol Parameters =====
    // C: Total number of cores available for work processing
    core_count: u16 = 341,
    // V: Total number of validators in the network
    validators_count: u16 = 1023,
    // V_s: Number of validators required for a super-majority (2/3 + 1)
    validators_super_majority: u32 = 683,

    // ===== Time and Slot Parameters =====

    // P: Slot period in seconds
    slot_period: u16 = 6,
    // E: Number of slots in an epoch
    epoch_length: u32 = 600,
    // Y: Slot within epoch when ticket submission ends
    ticket_submission_end_epoch_slot: u32 = 500,
    // A: Period in seconds between audit tranches
    audit_tranche_period: u8 = 8,
    // R: Rotation period for validator-core assignments (in timeslots)
    validator_rotation_period: u16 = 10,

    // ===== Balance and Economic Parameters =====

    // BS: Basic minimum balance required for all services
    basic_service_balance: u64 = 100,
    // BI: Additional minimum balance required per item of elective service state
    min_balance_per_item: u64 = 10,
    // BL: Additional minimum balance required per octet of elective service state
    min_balance_per_octet: u64 = 1,

    // ===== Storage and History Parameters =====

    // H: Size of recent history in blocks
    recent_history_size: u16 = 8,
    // D: Period in timeslots after which unreferenced preimages may be expunged
    preimage_expungement_period: u32 = 19_200,
    // L: Maximum age in timeslots of the lookup anchor
    max_lookup_anchor_age: u32 = 14_400,
    // U: Period in timeslots after which reported but unavailable work may be replaced
    work_replacement_period: u16 = 5,

    // ===== Gas Allocation Parameters =====

    // GA: Gas allocated to a core for Accumulation
    // See: https://github.com/w3f/jamtestvectors/pull/20#issuecomment-2526203035
    gas_alloc_accumulation: u64 = 10_000_000,
    // GI: Gas allocated to invoke work-package Is-Authorized logic
    gas_alloc_is_authorized: u64 = 50_000_000,
    // GR: Total gas allocated for work-package Refine logic
    gas_alloc_refine: u64 = 5_000_000_000,
    // GT: Total gas allocated across all cores for Accumulation
    total_gas_alloc_accumulation: u64 = 3_500_000_000,

    // ===== Work Package and Report Parameters =====
    // I: Maximum work items in a package
    max_work_items_per_package: u16 = 16,
    // J: Maximum dependencies in work report segment-root lookup dictionary
    max_number_of_dependencies_for_work_reports: u16 = 8,
    // T: Maximum extrinsics in a work-package
    max_extrinsics_per_work_package: u16 = 128,
    // WM: Maximum imports in a work-package
    max_imports_per_work_package: u16 = 3072,
    // WX: Maximum exports in a work-package
    max_exports_per_work_package: u16 = 3072,
    // WR: Maximum size of an encoded work-report in octets
    max_work_report_size: u32 = 48 * (1 << 10), // 48 KB
    // WB: Maximum size of encoded work-package with extrinsic data and import implications
    max_work_package_size_with_extrinsics: u32 = 13_791_360, // ~13.15 MB (graypaper v0.7.2)

    // ===== Authorization and Queue Parameters =====

    // O: Maximum items in the authorizations pool
    max_authorizations_pool_items: u16 = 8,
    // Q: Maximum items in the authorizations queue
    max_authorizations_queue_items: u16 = 80,
    // S: Maximum entries in the accumulation queue
    max_accumulation_queue_entries: u32 = 1024,

    // ===== Validator and Ticket Parameters =====

    // K: Maximum tickets submitted in a single extrinsic
    max_tickets_per_extrinsic: u16 = 16,
    // N: Ticket entries per validator
    max_ticket_entries_per_validator: u16 = 2,
    // F: Audit bias factor - expected additional auditors per no-show
    audit_bias_factor: u8 = 2,

    // ===== Code Size Limits =====

    // WA: Maximum size of authorization code in octets
    max_authorization_code_size: u32 = 64_000,
    // WC: Maximum size of service code in octets
    max_service_code_size: u32 = 4_000_000,

    // ===== Erasure Coding Parameters =====

    // WE: Basic size of erasure-coded pieces in octets
    // DERIVED: WE = W_G / W_P where W_G = 4104 (constant)
    erasure_coded_piece_size: u32 = 684,
    // WP: Number of erasure-coded pieces in a segment
    erasure_coded_pieces_per_segment: u32 = 6,
    // WG: Size of a segment in octets - MUST always be 4104 (JAM protocol constant)
    // INVARIANT: W_P * W_E = 4104 (enforced at compile time)
    segment_size: u16 = 4104,

    // ===== PVM (Polka Virtual Machine) Parameters =====

    // ZA: PVM dynamic address alignment factor
    pvm_dynamic_address_alignment_factor: u8 = 2,
    // ZI: Standard PVM program initialization input data size
    pvm_program_init_input_size: u32 = 1 << 24, // 16,777,216 bytes
    // ZP: Standard PVM program initialization page size
    pvm_program_init_page_size: u16 = 1 << 12, // 4,096 bytes
    // ZQ: Standard PVM program initialization segment size
    pvm_program_init_segment_size: u32 = 1 << 16, // 65,536 bytes

    // ===== Other Parameters =====

    // WT: Size of a transfer memo in octets
    transfer_memo_size: u32 = 128,

    // Computed field for availability bitfield size
    // This should match (core_count + 7) / 8
    avail_bitfield_bytes: usize = (341 + 7) / 8,

    // ===== Helper Functions =====

    /// Calculate the size of availability bitfield in bytes
    pub fn availBitfieldBytes(self: *const Params) usize {
        return (self.core_count + 7) / 8;
    }

    /// Get the Time type configured with this parameter set
    pub fn Time(comptime self: *const Params) type {
        return time.Time(self.epoch_length, self.slot_period, self.ticket_submission_end_epoch_slot);
    }

    /// Validate parameter consistency
    pub fn validate(self: *const Params) !void {
        // Ensure validators_super_majority is correctly calculated
        const expected_super_majority = (self.validators_count * 2) / 3 + 1;
        if (self.validators_super_majority != expected_super_majority) {
            return error.InvalidSuperMajority;
        }

        // Ensure avail_bitfield_bytes matches core_count
        if (self.avail_bitfield_bytes != self.availBitfieldBytes()) {
            return error.InvalidBitfieldSize;
        }

        // Ensure segment size equals the protocol constant 4104
        if (self.segment_size != self.erasure_coded_pieces_per_segment * self.erasure_coded_piece_size) {
            return error.InvalidErasureCodingParams;
        }
    }

    /// Format parameters for display
    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        var indented_writer = tfmt.IndentedWriter(@TypeOf(writer)).init(writer);
        const iw = indented_writer.writer();

        try tfmt.formatValue(self.*, iw, .{});
    }
};

// ===== Pre-configured Parameter Sets =====

/// Tiny parameter set for testing with minimal validators and cores
/// See: https://docs.jamcha.in/basics/chain-spec/tiny
pub const TINY_PARAMS = Params{
    // Core counts
    .validators_count = 6,
    .validators_super_majority = 5, // (6 * 2/3) + 1 = 5
    .core_count = 2,
    .avail_bitfield_bytes = 1, // (2 + 7) / 8 = 1

    // Time parameters
    .slot_period = 6,
    .epoch_length = 12,
    .ticket_submission_end_epoch_slot = 10,
    .validator_rotation_period = 4,

    // Ticket parameters
    .max_ticket_entries_per_validator = 3,
    .max_tickets_per_extrinsic = 3,

    // Storage parameters
    .recent_history_size = 8,
    .preimage_expungement_period = 32, // Override from default 19,200

    // Erasure coding
    .erasure_coded_piece_size = 4, // WE = W_G / W_P = 4104 / 1026 = 4
    .erasure_coded_pieces_per_segment = 1026,

    // GT: Total gas allocated across all cores for Accumulation
    // https://github.com/davxy/jam-test-vectors/pull/90#issuecomment-3217905803
    .total_gas_alloc_accumulation = 20_000_000,
    .gas_alloc_refine = 1_000_000_000, // Found by decoding the fetch value

    // L: Maximum age in timeslots of the lookup anchor
    .max_lookup_anchor_age = 24,

    // All other fields use default values
};

// Compile-time validation for TINY_PARAMS
comptime {
    const tiny_product = TINY_PARAMS.erasure_coded_pieces_per_segment * TINY_PARAMS.erasure_coded_piece_size;
    if (tiny_product != 4104) {
        @compileError(std.fmt.comptimePrint(
            "TINY_PARAMS: Invalid erasure coding parameters. W_P * W_E = {} * {} = {}, must equal 4104",
            .{ TINY_PARAMS.erasure_coded_pieces_per_segment, TINY_PARAMS.erasure_coded_piece_size, tiny_product },
        ));
    }
    if (TINY_PARAMS.segment_size != 4104) {
        @compileError("TINY_PARAMS.segment_size must be 4104");
    }
}

/// Full parameter set with default values for production use
pub const FULL_PARAMS = Params{};

// Compile-time validation for FULL_PARAMS (default)
comptime {
    const full_product = FULL_PARAMS.erasure_coded_pieces_per_segment * FULL_PARAMS.erasure_coded_piece_size;
    if (full_product != 4104) {
        @compileError(std.fmt.comptimePrint(
            "FULL_PARAMS: Invalid erasure coding parameters. W_P * W_E = {} * {} = {}, must equal 4104",
            .{ FULL_PARAMS.erasure_coded_pieces_per_segment, FULL_PARAMS.erasure_coded_piece_size, full_product },
        ));
    }
    if (FULL_PARAMS.segment_size != 4104) {
        @compileError("FULL_PARAMS.segment_size must be 4104");
    }
}

test "format JamParams" {
    std.debug.print("\n{s}\n", .{TINY_PARAMS});
}

test "validate params" {
    // Test TINY_PARAMS validation
    try TINY_PARAMS.validate();

    // Test FULL_PARAMS validation
    try FULL_PARAMS.validate();

    // Test invalid super majority
    var invalid_params = TINY_PARAMS;
    invalid_params.validators_super_majority = 3; // Should be 5
    try std.testing.expectError(error.InvalidSuperMajority, invalid_params.validate());

    // Test invalid bitfield size
    invalid_params = TINY_PARAMS;
    invalid_params.avail_bitfield_bytes = 2; // Should be 1
    try std.testing.expectError(error.InvalidBitfieldSize, invalid_params.validate());
}
