const std = @import("std");
const jam_params = @import("jam_params.zig");

const ParamMetadata = struct {
    symbol: []const u8,
    description: []const u8,
};

fn getParamMetadata(field_name: []const u8) ParamMetadata {
    const metadata_map = std.StaticStringMap(ParamMetadata).initComptime(.{
        .{ "audit_tranche_period", ParamMetadata{ .symbol = "A", .description = "The period, in seconds, between audit tranches" } },
        .{ "min_balance_per_item", ParamMetadata{ .symbol = "BI", .description = "The additional minimum balance required per item of elective service state" } },
        .{ "min_balance_per_octet", ParamMetadata{ .symbol = "BL", .description = "The additional minimum balance required per octet of elective service state" } },
        .{ "basic_service_balance", ParamMetadata{ .symbol = "BS", .description = "The basic minimum balance which all services require" } },
        .{ "core_count", ParamMetadata{ .symbol = "C", .description = "The total number of cores" } },
        .{ "preimage_expungement_period", ParamMetadata{ .symbol = "D", .description = "The period in timeslots after which an unreferenced preimage may be expunged" } },
        .{ "epoch_length", ParamMetadata{ .symbol = "E", .description = "The number of slots in an epoch" } },
        .{ "audit_bias_factor", ParamMetadata{ .symbol = "F", .description = "The audit bias factor, expected additional auditors per no-show" } },
        .{ "gas_alloc_accumulation", ParamMetadata{ .symbol = "GA", .description = "The total gas allocated to a core for Accumulation" } },
        .{ "gas_alloc_is_authorized", ParamMetadata{ .symbol = "GI", .description = "The gas allocated to invoke a work-package Is-Authorized logic" } },
        .{ "gas_alloc_refine", ParamMetadata{ .symbol = "GR", .description = "The total gas allocated for a work-package Refine logic" } },
        .{ "total_gas_alloc_accumulation", ParamMetadata{ .symbol = "GT", .description = "The total gas allocated across all cores for Accumulation" } },
        .{ "recent_history_size", ParamMetadata{ .symbol = "H", .description = "The size of recent history, in blocks" } },
        .{ "max_work_items_per_package", ParamMetadata{ .symbol = "I", .description = "The maximum amount of work items in a package" } },
        .{ "max_number_of_dependencies_for_work_reports", ParamMetadata{ .symbol = "J", .description = "The maximum amount of dependencies in a work report segment-root lookup dictionary and the number of pre-requisites for a work item" } },
        .{ "max_tickets_per_extrinsic", ParamMetadata{ .symbol = "K", .description = "The maximum number of tickets which may be submitted in a single extrinsic" } },
        .{ "max_lookup_anchor_age", ParamMetadata{ .symbol = "L", .description = "The maximum age in timeslots of the lookup anchor" } },
        .{ "max_ticket_entries_per_validator", ParamMetadata{ .symbol = "N", .description = "The number of ticket entries per validator" } },
        .{ "max_authorizations_pool_items", ParamMetadata{ .symbol = "O", .description = "The maximum number of items in the authorizations pool" } },
        .{ "slot_period", ParamMetadata{ .symbol = "P", .description = "The slot period, in seconds" } },
        .{ "max_authorizations_queue_items", ParamMetadata{ .symbol = "Q", .description = "The maximum number of items in the authorizations queue" } },
        .{ "validator_rotation_period", ParamMetadata{ .symbol = "R", .description = "The rotation period of validator-core assignments, in timeslots" } },
        .{ "max_accumulation_queue_entries", ParamMetadata{ .symbol = "S", .description = "The maximum number of entries in the accumulation queue" } },
        .{ "max_extrinsics_per_work_package", ParamMetadata{ .symbol = "T", .description = "The maximum number of extrinsics in a work-package" } },
        .{ "work_replacement_period", ParamMetadata{ .symbol = "U", .description = "The period in timeslots after which reported but unavailable work may be replaced" } },
        .{ "validators_count", ParamMetadata{ .symbol = "V", .description = "The total number of validators" } },
        .{ "validators_super_majority", ParamMetadata{ .symbol = "V_s", .description = "The number of validators required for a super-majority" } },
        .{ "max_authorization_code_size", ParamMetadata{ .symbol = "WA", .description = "The maximum size of authorization code in octets" } },
        .{ "max_work_package_size_with_extrinsics", ParamMetadata{ .symbol = "WB", .description = "The maximum size of an encoded work-package together with its extrinsic data and import implications, in octets" } },
        .{ "max_service_code_size", ParamMetadata{ .symbol = "WC", .description = "The maximum size of service code in octets" } },
        .{ "erasure_coded_piece_size", ParamMetadata{ .symbol = "WE", .description = "The basic size of erasure-coded pieces in octets" } },
        .{ "segment_size", ParamMetadata{ .symbol = "WG", .description = "The size of a segment in octets (WP * WE)" } },
        .{ "max_imports_per_work_package", ParamMetadata{ .symbol = "WM", .description = "The maximum number of imports in a work-package" } },
        .{ "erasure_coded_pieces_per_segment", ParamMetadata{ .symbol = "WP", .description = "The number of erasure-coded pieces in a segment" } },
        .{ "max_work_report_size", ParamMetadata{ .symbol = "WR", .description = "The maximum size of an encoded work-report in octets" } },
        .{ "exported_segment_size", ParamMetadata{ .symbol = "WS", .description = "The size of an exported segment in erasure-coded pieces (same as WP)" } },
        .{ "transfer_memo_size", ParamMetadata{ .symbol = "WT", .description = "The size of a transfer memo in octets" } },
        .{ "max_exports_per_work_package", ParamMetadata{ .symbol = "WX", .description = "The maximum number of exports in a work-package" } },
        .{ "ticket_submission_end_epoch_slot", ParamMetadata{ .symbol = "Y", .description = "The number of slots into an epoch at which ticket-submission ends" } },
        .{ "pvm_dynamic_address_alignment_factor", ParamMetadata{ .symbol = "ZA", .description = "The pvm dynamic address alignment factor" } },
        .{ "pvm_program_init_input_size", ParamMetadata{ .symbol = "ZI", .description = "The standard pvm program initialization input data size" } },
        .{ "pvm_program_init_page_size", ParamMetadata{ .symbol = "ZP", .description = "The standard pvm program initialization page size" } },
        .{ "pvm_program_init_segment_size", ParamMetadata{ .symbol = "ZQ", .description = "The standard pvm program initialization segment size" } },
    });

    return metadata_map.get(field_name) orelse ParamMetadata{ .symbol = "?", .description = "Unknown parameter" };
}

pub fn formatParamsText(params: jam_params.Params, params_type: []const u8, writer: anytype) !void {
    try writer.print("JAM Protocol Parameters ({s})\n", .{params_type});
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    const typeInfo = @typeInfo(jam_params.Params);
    inline for (typeInfo.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "avail_bitfield_bytes")) {
        } else {
            const metadata = getParamMetadata(field.name);
            const value = @field(params, field.name);

            try writer.print("{s:<4} - ", .{metadata.symbol});

            var first_word = true;
            var after_underscore = false;
            for (field.name) |c| {
                if (c == '_') {
                    try writer.writeByte(' ');
                    after_underscore = true;
                } else if (first_word or after_underscore) {
                    try writer.writeByte(std.ascii.toUpper(c));
                    first_word = false;
                    after_underscore = false;
                } else {
                    try writer.writeByte(c);
                }
            }

            try writer.print(": {d}\n", .{value});
            try writer.print("      {s}\n\n", .{metadata.description});
        }
    }
}

pub fn formatParamsJson(params: jam_params.Params, params_type: []const u8, writer: anytype) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"params_type\": \"{s}\",\n", .{params_type});
    try writer.writeAll("  \"parameters\": {\n");

    const typeInfo = @typeInfo(jam_params.Params);
    var first = true;
    inline for (typeInfo.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "avail_bitfield_bytes")) {
        } else {
            if (!first) {
                try writer.writeAll(",\n");
            }
            first = false;

            const metadata = getParamMetadata(field.name);
            const value = @field(params, field.name);

            try writer.print("    \"{s}\": {{\n", .{metadata.symbol});
            try writer.print("      \"name\": \"{s}\",\n", .{field.name});
            try writer.print("      \"value\": {d},\n", .{value});
            try writer.print("      \"type\": \"{s}\",\n", .{@typeName(field.type)});
            try writer.print("      \"description\": \"{s}\"\n", .{metadata.description});
            try writer.writeAll("    }");
        }
    }

    try writer.writeAll("\n  }\n");
    try writer.writeAll("}\n");
}

