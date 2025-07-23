const std = @import("std");
const state = @import("../state.zig");
const state_decoding = @import("../state_decoding.zig");
const types = @import("../types.zig");
const delta_reconstruction = @import("delta_reconstruction.zig");

const state_dictionary = @import("../state_dictionary.zig");

const MerklizationDictionary = @import("../state_dictionary.zig").MerklizationDictionary;
const Params = @import("../jam_params.zig").Params;

pub const detectKeyType = @import("../state_dictionary/key_type_detection.zig").detectKeyType;

const trace = @import("../tracing.zig").scoped(.codec);

/// Reconstructs a JamState from a MerklizationDictionary by decoding its entries
pub fn reconstructState(
    comptime params: Params,
    allocator: std.mem.Allocator,
    dict: *const MerklizationDictionary,
) !state.JamState(params) {
    var span = trace.span(.reconstruct_state);
    defer span.deinit();

    span.debug("Starting state reconstruction with dictionary size: {d}", .{dict.entries.count()});

    // Create a decoding context for error tracking
    var decoding_context = state_decoding.DecodingContext.init(allocator);
    defer decoding_context.deinit();

    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // NOTE: we initialize delta here, as we always want a delta to be available
    // also when we have a merklization dictioray without any service accounts
    jam_state.delta = state.Delta.init(allocator);

    span.debug("Initialized empty JamState", .{});

    // Buffer for storing preimage lookup entries until we can process them
    var preimage_lookup_buffer = std.ArrayList(state_dictionary.DictEntry).init(allocator);
    defer preimage_lookup_buffer.deinit();

    // Helper function to get reader for value

    const fbs = std.io.fixedBufferStream;

    // Iterate through all entries
    var it = dict.entries.iterator();
    var entry_count: usize = 0;
    while (it.next()) |entry| {
        entry_count += 1;
        const key = entry.key_ptr.*;
        const dict_entry = entry.value_ptr.*;

        var entry_span = span.child(.process_entry);
        defer entry_span.deinit();

        entry_span.debug("Processing entry {d}/{d}: key length={d}, value length={d}", .{ entry_count, dict.entries.count(), key.len, dict_entry.value.len });

        const key_type = detectKeyType(key);
        entry_span.trace("Key type: {s}, key: 0x{s}", .{ @tagName(key_type), std.fmt.fmtSliceHexLower(&key) });

        switch (key_type) {
            .state_component => switch (key[0]) {
                1 => {
                    var component_span = entry_span.child(.decode_alpha);
                    defer component_span.deinit();
                    component_span.debug("Decoding alpha component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const alpha_params = comptime state_decoding.alpha.DecoderParams.fromJamParams(params);
                    jam_state.alpha = try state_decoding.alpha.decode(
                        alpha_params,
                        allocator,
                        &decoding_context,
                        f.reader(),
                    );
                },
                2 => {
                    var component_span = entry_span.child(.decode_phi);
                    defer component_span.deinit();
                    component_span.debug("Decoding phi component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const phi_params = comptime state_decoding.phi.DecoderParams.fromJamParams(params);
                    jam_state.phi = try state_decoding.phi.decode(phi_params, allocator, &decoding_context, f.reader());
                },

                3 => {
                    entry_span.debug("Decoding beta component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.beta = try state_decoding.beta.decode(allocator, &decoding_context, f.reader());
                },
                4 => {
                    entry_span.debug("Decoding gamma component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const gamma_params = comptime state_decoding.gamma.DecoderParams.fromJamParams(params);
                    jam_state.gamma = try state_decoding.gamma.decode(gamma_params, allocator, &decoding_context, f.reader());
                },
                5 => {
                    entry_span.debug("Decoding psi component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.psi = try state_decoding.psi.decode(allocator, &decoding_context, f.reader());
                },
                6 => {
                    entry_span.debug("Decoding eta component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.eta = try state_decoding.eta.decode(allocator, &decoding_context, f.reader());
                },
                7 => {
                    entry_span.debug("Decoding iota component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.iota = try state_decoding.iota.decode(allocator, &decoding_context, params.validators_count, f.reader());
                },
                8 => {
                    entry_span.debug("Decoding kappa component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.kappa = try state_decoding.kappa.decode(allocator, &decoding_context, params.validators_count, f.reader());
                },
                9 => {
                    entry_span.debug("Decoding lambda component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.lambda = try state_decoding.lambda.decode(allocator, &decoding_context, params.validators_count, f.reader());
                },
                10 => {
                    entry_span.debug("Decoding rho component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const rho_params = comptime state_decoding.rho.DecoderParams.fromJamParams(params);
                    jam_state.rho = try state_decoding.rho.decode(rho_params, allocator, &decoding_context, f.reader());
                },
                11 => {
                    entry_span.debug("Decoding tau component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.tau = try state_decoding.tau.decode(allocator, &decoding_context, f.reader());
                },
                12 => {
                    entry_span.debug("Decoding chi component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    jam_state.chi = try state_decoding.chi.decode(allocator, &decoding_context, f.reader());
                },
                13 => {
                    entry_span.debug("Decoding pi component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const pi_params = comptime state_decoding.pi.DecoderParams.fromJamParams(params);
                    jam_state.pi = try state_decoding.pi.decode(pi_params, allocator, &decoding_context, f.reader());
                },
                14 => {
                    entry_span.debug("Decoding theta component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const theta_params = comptime state_decoding.theta.DecoderParams.fromJamParams(params);
                    jam_state.theta = try state_decoding.theta.decode(theta_params, allocator, &decoding_context, f.reader());
                },
                15 => {
                    entry_span.debug("Decoding xi component (id={d})", .{key[0]});
                    var f = fbs(dict_entry.value);
                    const xi_params = comptime state_decoding.xi.DecoderParams.fromJamParams(params);
                    jam_state.xi = try state_decoding.xi.decode(xi_params, allocator, &decoding_context, f.reader());
                },
                else => {
                    entry_span.err("Unknown state component ID: {d}", .{key[0]});
                    return error.UnknownStateComponent;
                },
            },
            .delta_base => {
                var delta_span = entry_span.child(.process_delta_base);
                defer delta_span.deinit();
                delta_span.debug("Processing delta base entry", .{});

                try delta_reconstruction.reconstructServiceAccountBase(allocator, &jam_state.delta.?, key, dict_entry.value);
            },
            .delta_storage => {
                var storage_span = entry_span.child(.process_delta_storage);
                defer storage_span.deinit();
                storage_span.debug("Processing delta storage entry", .{});

                // Passing dict entry as we need metadata to restore this
                try delta_reconstruction.reconstructStorageEntry(allocator, &jam_state.delta.?, dict_entry);
            },
            .delta_preimage => {
                var preimage_span = entry_span.child(.process_delta_preimage);
                defer preimage_span.deinit();
                preimage_span.debug("Processing delta preimage entry", .{});

                try delta_reconstruction.reconstructPreimageEntry(allocator, &jam_state.delta.?, jam_state.tau, dict_entry);
            },
            .delta_preimage_lookup => {
                var lookup_span = entry_span.child(.buffer_delta_preimage_lookup);
                defer lookup_span.deinit();
                lookup_span.debug("Buffering delta lookup entry for later processing", .{});

                // Buffer this entry for processing after all other entries
                try preimage_lookup_buffer.append(dict_entry);
            },
        }
    }

    // Second pass: Process buffered preimage lookup entries now that all preimages are loaded
    var lookup_span = span.child(.process_lookups);
    defer lookup_span.deinit();

    lookup_span.debug("Processing {d} buffered preimage lookup entries", .{preimage_lookup_buffer.items.len});

    for (preimage_lookup_buffer.items, 0..) |buffered, i| {
        var entry_span = lookup_span.child(.process_buffered_lookup);
        defer entry_span.deinit();

        entry_span.debug("Processing buffered lookup entry {d}/{d}", .{ i + 1, preimage_lookup_buffer.items.len });
        try delta_reconstruction.reconstructPreimageLookupEntry(allocator, &jam_state.delta.?, buffered);
    }

    span.debug("State reconstruction completed successfully. Processed {d} entries total", .{
        entry_count,
    });

    return jam_state;
}
