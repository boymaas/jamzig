const std = @import("std");
const jam_params = @import("../../jam_params.zig");
const types = @import("../../types.zig");

const state_dictionary = @import("../../state_dictionary.zig");

const jamtestnet = @import("../../jamtestnet.zig");
const jamtestnet_json = @import("../json.zig");
const jamtestnet_export = @import("../export.zig");

const stf = @import("stf.zig");

const StateTransition = jamtestnet_export.StateTransition;
const KeyVal = jamtestnet_export.KeyVal;

fn buildIdString(allocator: std.mem.Allocator, metadata: *const state_dictionary.DictMetadata) ![]u8 {
    switch (metadata.*) {
        .state_component => |m| {
            return std.fmt.allocPrint(allocator, "c{d}", .{m.component_index});
        },
        .delta_base => |_| {
            return std.fmt.allocPrint(allocator, "service_account", .{});
        },
        .delta_storage => |_| {
            return std.fmt.allocPrint(allocator, "account_storage", .{});
        },
        .delta_preimage => |_| {
            return std.fmt.allocPrint(allocator, "account_preimage", .{});
        },
        .delta_preimage_lookup => |_| {
            return std.fmt.allocPrint(allocator, "account_lookup", .{});
        },
    }
}

fn buildMetadataString(allocator: std.mem.Allocator, metadata: *const state_dictionary.DictMetadata) ![]u8 {
    switch (metadata.*) {
        .state_component => |_| {
            // State components don't have additional metadata description
            return allocator.dupe(u8, "");
        },
        .delta_base => |m| {
            // Format: s=<service_index>|c=<code_hash> b=<balance> g=<min_gas> m=<min_memo_gas> l=<bytes> i=<items>|clen=32
            const service_index = m.service_index;
            return std.fmt.allocPrint(allocator, "s={d}", .{service_index});
        },
        .delta_storage => |m| {
            // Format: s=<service_index>|hk=<hex_masked_key> k=<hex_key_suffix>
            // Extract first 4 bytes for masked_key and remaining for suffix
            return std.fmt.allocPrint(allocator, "s={d}|hk=0xFFFF{s}", .{
                m.service_index,
                std.fmt.fmtSliceHexLower(&m.storage_key),
            });
        },
        .delta_preimage => |m| {
            // Format: s=<service_index>|h=<hash>|plen=<preimage_length>
            return std.fmt.allocPrint(allocator, "s={d}|h=0x{s}|plen={d}", .{
                m.service_index,
                std.fmt.fmtSliceHexLower(&m.hash),
                m.preimage_length,
            });
        },
        .delta_preimage_lookup => |m| {
            // Format: s=<service_index>|h=<hash> l=<length>|t=[<timeslots>] tlen=<timeslot_count>
            // Note: Currently we always show empty timeslots array as that's what's shown in the example
            return std.fmt.allocPrint(allocator, "s={d}|h=0x{s} l={d}|t=[]", .{
                m.service_index,
                std.fmt.fmtSliceHexLower(&m.hash),
                m.preimage_length,
            });
        },
    }
}
