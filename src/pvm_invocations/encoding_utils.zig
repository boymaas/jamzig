const std = @import("std");
const types = @import("../types.zig");
const Params = @import("../jam_params.zig").Params;

pub fn encodeJamParams(allocator: std.mem.Allocator, params_val: Params) ![]u8 {
    const EncodeMap = struct {
        BI: u64, // additional_minimum_balance_per_item
        BL: u64, // additional_minimum_balance_per_octet
        BS: u64, // basic_minimum_balance
        C: u16, // total_number_of_cores
        D: u32, // preimage_expulsion_period
        E: u32, // timeslots_per_epoch
        GA: u64, // max_allocated_gas_accumulation
        GI: u64, // max_allocated_gas_is_authorized
        GR: u64, // max_allocated_gas_refine
        GT: u64, // total_gas_accumulation
        H: u16, // max_recent_blocks
        I: u16, // max_number_of_items
        J: u16, // max_number_of_dependency_items
        K: u16, // max_tickets_per_extrinsic
        L: u32, // max_timeslots_for_preimage
        N: u16, // max_ticket_entries_per_validator
        O: u16, // max_authorizers_per_core
        P: u16, // slot_period_in_seconds
        Q: u16, // pending_authorizers_queue_size
        R: u16, // validator_rotation_period
        T: u16, // max_number_of_extrinsics
        U: u16, // work_report_timeout_period
        V: u16, // number_of_validators
        WA: u32, // maximum_size_is_authorized_code
        WB: u32, // max_work_package_size
        WC: u32, // max_size_service_code
        WE: u32, // erasure_coding_chunk_size
        WM: u32, // max_number_of_imports_exports
        WP: u32, // number_of_erasure_codec_pieces_in_segment
        WR: u32, // max_work_package_size_bytes
        WT: u32, // transfer_memo_size_bytes
        WX: u32, // max_number_of_exports
        Y: u32, // ticket_submission_time_slots
    };

    const constants = EncodeMap{
        .BI = params_val.min_balance_per_item,
        .BL = params_val.min_balance_per_octet,
        .BS = params_val.basic_service_balance,
        .C = params_val.core_count,
        .D = params_val.preimage_expungement_period,
        .E = params_val.epoch_length,
        .GA = params_val.gas_alloc_accumulation,
        .GI = params_val.gas_alloc_is_authorized,
        .GR = params_val.gas_alloc_refine,
        .GT = params_val.total_gas_alloc_accumulation,
        .H = params_val.recent_history_size,
        .I = params_val.max_work_items_per_package,
        .J = params_val.max_number_of_dependencies_for_work_reports,
        .K = params_val.max_tickets_per_extrinsic,
        .L = params_val.max_lookup_anchor_age,
        .N = params_val.max_ticket_entries_per_validator,
        .O = params_val.max_authorizations_pool_items,
        .P = params_val.slot_period,
        .Q = params_val.max_authorizations_queue_items,
        .R = params_val.validator_rotation_period,
        .T = params_val.max_extrinsics_per_work_package,
        .U = params_val.work_replacement_period,
        .V = params_val.validators_count,
        .WA = params_val.max_authorization_code_size,
        .WB = params_val.max_work_package_size_with_extrinsics,
        .WC = params_val.max_service_code_size,
        .WE = params_val.erasure_coded_piece_size,
        .WM = params_val.max_imports_per_work_package,
        .WP = params_val.erasure_coded_pieces_per_segment,
        .WR = params_val.max_work_report_size,
        .WT = params_val.transfer_memo_size,
        .WX = params_val.max_exports_per_work_package,
        .Y = params_val.ticket_submission_end_epoch_slot,
    };

    return try @import("../codec.zig").serializeAlloc(EncodeMap, .{}, allocator, constants);
}

pub fn encodeOperandTuples(allocator: std.mem.Allocator, operand_tuples: []const @import("accumulate.zig").AccumulationOperand) ![]u8 {
    const codec = @import("../codec.zig");

    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    try codec.writeInteger(operand_tuples.len, buffer.writer());

    for (operand_tuples) |operand| {
        try buffer.writer().writeByte(0);
        try operand.encode(.{}, buffer.writer());
    }

    return buffer.toOwnedSlice();
}

pub fn encodeOperandTuple(allocator: std.mem.Allocator, operand_tuple: *const @import("accumulate.zig").AccumulationOperand) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    try buffer.writer().writeByte(0);
    try operand_tuple.encode(.{}, buffer.writer());

    return buffer.toOwnedSlice();
}

pub fn encodeTransfers(allocator: std.mem.Allocator, transfers: []const @import("accumulate/types.zig").DeferredTransfer) ![]u8 {
    const codec = @import("../codec.zig");
    return try codec.serializeAlloc([]const @import("accumulate/types.zig").DeferredTransfer, .{}, allocator, transfers);
}

pub fn encodeTransfer(allocator: std.mem.Allocator, transfer: *const @import("accumulate/types.zig").DeferredTransfer) ![]u8 {
    const codec = @import("../codec.zig");
    return try codec.serializeAlloc(@import("accumulate/types.zig").DeferredTransfer, .{}, allocator, transfer.*);
}

pub fn encodeCombinedInputs(
    allocator: std.mem.Allocator,
    transfers: []const @import("accumulate.zig").TransferOperand,
    operands: []const @import("accumulate.zig").AccumulationOperand,
) ![]u8 {
    const codec = @import("../codec.zig");
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    const total_count = transfers.len + operands.len;

    try codec.writeInteger(total_count, buffer.writer());

    for (transfers) |transfer| {
        try buffer.writer().writeByte(1);
        try codec.serialize(@import("accumulate.zig").TransferOperand, .{}, buffer.writer(), transfer);
    }

    for (operands) |operand| {
        try buffer.writer().writeByte(0);
        try operand.encode(.{}, buffer.writer());
    }

    return buffer.toOwnedSlice();
}

pub fn encodeTransferAsInput(
    allocator: std.mem.Allocator,
    transfer: *const @import("accumulate.zig").TransferOperand,
) ![]u8 {
    const codec = @import("../codec.zig");
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    try buffer.writer().writeByte(1);
    try codec.serialize(@import("accumulate.zig").TransferOperand, .{}, buffer.writer(), transfer.*);

    return buffer.toOwnedSlice();
}
