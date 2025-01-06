const std = @import("std");
const time = @import("time.zig");

/// This struct defines the protocol parameters used throughout the system.
/// Each field represents a specific constant derived from the protocol's
/// specification. The constants are annotated with their corresponding symbols
/// (e.g., E, N, K, etc.) and cover various aspects which are essential for the
/// correct functioning of the protocol.
pub const Params = struct {
    // A: The period, in seconds, between audit tranches
    audit_tranche_period: u8 = 8, // A
    // BI: The additional minimum balance required per item of elective service state
    min_balance_per_item: u32 = 10, // BI
    // BL: The additional minimum balance required per octet of elective service state
    min_balance_per_octet: u32 = 1, // BL
    // BS: The basic minimum balance which all services require
    basic_service_balance: u32 = 100, // BS
    // C: The total number of cores
    core_count: u16 = 341, // C
    // D: The period in timeslots after which an unreferenced preimage may be expunged
    preimage_expungement_period: u32 = 28_800, // D
    // E: The number of slots in an epoch
    epoch_length: u32 = 600, // E
    // F: The audit bias factor, expected additional auditors per no-show
    audit_bias_factor: u8 = 2, // F
    // GA: The total gas allocated to a core for Accumulation
    // See: https://github.com/w3f/jamtestvectors/pull/20#issuecomment-2526203035
    gas_alloc_accumulation: u32 = 10_000_000, // GA
    // GI: The gas allocated to invoke a work-package’s Is-Authorized logic
    gas_alloc_is_authorized: u32 = 1_000_000, // GI
    // GR: The total gas allocated for a work-package’s Refine logic
    gas_alloc_refine: u32 = 500_000_000, // GR
    // GT: The total gas allocated across all cores for Accumulation
    total_gas_alloc_accumulation: u32 = 35_000_000, // GT
    // H: The size of recent history, in blocks
    recent_history_size: u8 = 8, // H
    // I: The maximum amount of work items in a package
    max_work_items_per_package: u8 = 4, // I
    // J: The maximum amount of dependencies in a work report segment-root
    // lookup dictionary and the number of pre-requisites for a work item
    max_number_of_dependencies_for_work_reports: u8 = 8, // J
    // K: The maximum number of tickets which may be submitted in a single extrinsic
    max_tickets_per_extrinsic: u32 = 16, // K
    // L: The maximum age in timeslots of the lookup anchor
    max_lookup_anchor_age: u32 = 14_400, // L
    // N: The number of ticket entries per validator
    max_ticket_entries_per_validator: u8 = 2, // N
    // O: The maximum number of items in the authorizations pool
    max_authorizations_pool_items: u8 = 8, // O
    // P: The slot period, in seconds
    slot_period: u8 = 6, // P TODO: integrate these params into Tau and Safrole
    // Q: The maximum number of items in the authorizations queue
    max_authorizations_queue_items: u8 = 80, // Q
    // R: The rotation period of validator-core assignments, in timeslots
    validator_rotation_period: u32 = 10, // R
    // S: The maximum number of entries in the accumulation queue
    max_accumulation_queue_entries: u32 = 1024, // S
    // U: The period in timeslots after which reported but unavailable work may be replaced
    work_replacement_period: u8 = 5, // U
    // V: The total number of validators
    validators_count: u32 = 1023, // V
    // V_s: The number of validators required for a super-majority
    validators_super_majority: u32 = 683,
    // WC: The maximum size of service code in octets
    max_service_code_size: u32 = 4_000_000, // WC
    // WE: The basic size of erasure-coded pieces in octets
    erasure_coded_piece_size: u16 = 684, // WE
    // WM: The maximum number of entries in a work-package manifest
    max_manifest_entries: u16 = 2 ^ 11, // WM
    // WP: The maximum size of an encoded work-package together with its extrinsic data and import implications, in octets
    max_work_package_size: u32 = 12 * 2 ^ 20, // WP
    // WR: The maximum size of an encoded work-report in octets
    max_work_report_size: u32 = 96 * 2 ^ 10, // WR
    // WS: The size of an exported segment in erasure-coded pieces in octets
    exported_segment_size: u8 = 6, // WS
    // WT: The size of a transfer memo in octets
    transfer_memo_size: u8 = 128, // WT
    // Y: The number of slots into an epoch at which ticket-submission ends
    ticket_submission_end_epoch_slot: u32 = 500, // Y
    // ZA: The pvm dynamic address alignment factor
    pvm_dynamic_address_alignment_factor: u8 = 2, // ZA
    // ZI: The standard pvm program initialization input data size
    pvm_program_init_input_size: u32 = 2 ^ 24, // ZI
    // ZP: The standard pvm program initialization page size
    pvm_program_init_page_size: u16 = 2 ^ 14, // ZP
    // ZQ: The standard pvm program initialization segment size
    pvm_program_init_segment_size: u32 = 2 ^ 16, // ZQ
    //

    // NOTE: this has to be here for the codec,
    // -- (cores-count + 7) / 8
    avail_bitfield_bytes: usize = (341 + 7) / 8,

    // Helpers for tast init based on params
    pub fn Time(comptime self: *const Params) type {
        return time.Time(self.epoch_length, self.slot_period, self.ticket_submission_end_epoch_slot);
    }

    // Default format parameters
    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try @import("state_format/jam_params.zig").format(self, fmt, options, writer);
    }
};

pub const TINY_PARAMS = Params{
    .epoch_length = 12,
    .validator_rotation_period = 4, // R
    .ticket_submission_end_epoch_slot = 10,
    .max_ticket_entries_per_validator = 3, // NOTE: updated
    .recent_history_size = 8, // NOTE: explicitly set in testvectors
    .validators_count = 6,
    .validators_super_majority = 5,
    .core_count = 2,
    .avail_bitfield_bytes = (2 + 7) / 8,
};

pub const FULL_PARAMS = Params{};
