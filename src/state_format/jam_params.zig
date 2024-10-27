const std = @import("std");
const Params = @import("../jam_params.zig").Params;

pub fn format(
    self: *const Params,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll("Params{\n");
    try writer.print("  audit_tranche_period: {d}\n", .{self.audit_tranche_period});
    try writer.print("  min_balance_per_item: {d}\n", .{self.min_balance_per_item});
    try writer.print("  min_balance_per_octet: {d}\n", .{self.min_balance_per_octet});
    try writer.print("  basic_service_balance: {d}\n", .{self.basic_service_balance});
    try writer.print("  core_count: {d}\n", .{self.core_count});
    try writer.print("  preimage_expungement_period: {d}\n", .{self.preimage_expungement_period});
    try writer.print("  epoch_length: {d}\n", .{self.epoch_length});
    try writer.print("  audit_bias_factor: {d}\n", .{self.audit_bias_factor});
    try writer.print("  recent_history_size: {d}\n", .{self.recent_history_size});
    try writer.print("  max_work_items_per_package: {d}\n", .{self.max_work_items_per_package});
    try writer.print("  max_tickets_per_extrinsic: {d}\n", .{self.max_tickets_per_extrinsic});
    try writer.print("  max_lookup_anchor_age: {d}\n", .{self.max_lookup_anchor_age});
    try writer.print("  max_ticket_entries_per_validator: {d}\n", .{self.max_ticket_entries_per_validator});
    try writer.print("  max_authorizations_pool_items: {d}\n", .{self.max_authorizations_pool_items});
    try writer.print("  slot_period: {d}\n", .{self.slot_period});
    try writer.print("  max_authorizations_queue_items: {d}\n", .{self.max_authorizations_queue_items});
    try writer.print("  validator_rotation_period: {d}\n", .{self.validator_rotation_period});
    try writer.print("  max_accumulation_queue_entries: {d}\n", .{self.max_accumulation_queue_entries});
    try writer.print("  work_replacement_period: {d}\n", .{self.work_replacement_period});
    try writer.print("  validators_count: {d}\n", .{self.validators_count});
    try writer.print("  validators_super_majority: {d}\n", .{self.validators_super_majority});
    try writer.print("  max_service_code_size: {d}\n", .{self.max_service_code_size});
    try writer.print("  erasure_coded_piece_size: {d}\n", .{self.erasure_coded_piece_size});
    try writer.print("  max_manifest_entries: {d}\n", .{self.max_manifest_entries});
    try writer.print("  max_work_package_size: {d}\n", .{self.max_work_package_size});
    try writer.print("  max_work_report_size: {d}\n", .{self.max_work_report_size});
    try writer.print("  exported_segment_size: {d}\n", .{self.exported_segment_size});
    try writer.print("  transfer_memo_size: {d}\n", .{self.transfer_memo_size});
    try writer.print("  ticket_submission_end_epoch_slot: {d}\n", .{self.ticket_submission_end_epoch_slot});
    try writer.print("  pvm_dynamic_address_alignment_factor: {d}\n", .{self.pvm_dynamic_address_alignment_factor});
    try writer.print("  pvm_program_init_input_size: {d}\n", .{self.pvm_program_init_input_size});
    try writer.print("  pvm_program_init_page_size: {d}\n", .{self.pvm_program_init_page_size});
    try writer.print("  pvm_program_init_segment_size: {d}\n", .{self.pvm_program_init_segment_size});
    try writer.writeAll("}");
}
