const std = @import("std");
const state = @import("../state.zig");
const state_decoding = @import("../state_decoding.zig");
const types = @import("../types.zig");
const delta_reconstruction = @import("delta_reconstruction.zig");

const MerklizationDictionary = @import("../state_dictionary.zig").MerklizationDictionary;
const Params = @import("../jam_params.zig").Params;

const detectKeyType = @import("../state_dictionary/key_type_detection.zig").detectKeyType;

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

    var jam_state = try state.JamState(params).init(allocator);
    errdefer jam_state.deinit(allocator);

    // NOTE: we initialize delta here, as we always want a delta to be available
    // also when we have a merklization dictioray without any service accounts
    jam_state.delta = state.Delta.init(allocator);

    span.debug("Initialized empty JamState", .{});

    // Buffer for storing preimage lookup entries until we can process them
    var preimage_lookup_buffer = std.ArrayList(struct {
        key: [32]u8,
        value: []const u8,
    }).init(allocator);
    defer preimage_lookup_buffer.deinit();

    // Helper function to get reader for value

    const fbs = std.io.fixedBufferStream;

    // Iterate through all entries
    var it = dict.entries.iterator();
    var entry_count: usize = 0;
    while (it.next()) |entry| {
        entry_count += 1;
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        var entry_span = span.child(.process_entry);
        defer entry_span.deinit();

        entry_span.debug("Processing entry {d}/{d}: key length={d}, value length={d}", .{ entry_count, dict.entries.count(), key.len, value.len });

        const key_type = detectKeyType(key);
        entry_span.trace("Key type: {s}, key: 0x{s}", .{ @tagName(key_type), std.fmt.fmtSliceHexLower(&key) });

        switch (key_type) {
            .state_component => switch (key[0]) {
                1 => {
                    var component_span = entry_span.child(.decode_alpha);
                    defer component_span.deinit();
                    component_span.debug("Decoding alpha component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.alpha = try state_decoding.alpha.decode(params.core_count, f.reader());
                },
                2 => {
                    var component_span = entry_span.child(.decode_phi);
                    defer component_span.deinit();
                    component_span.debug("Decoding phi component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.phi = try state_decoding.phi.decode(params.core_count, params.max_authorizations_queue_items, allocator, f.reader());
                },

                3 => {
                    entry_span.debug("Decoding beta component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.beta = try state_decoding.beta.decode(allocator, f.reader());
                },
                4 => {
                    entry_span.debug("Decoding gamma component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.gamma = try state_decoding.gamma.decode(params, allocator, f.reader());
                },
                5 => {
                    entry_span.debug("Decoding psi component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.psi = try state_decoding.psi.decode(allocator, f.reader());
                },
                6 => {
                    entry_span.debug("Decoding eta component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.eta = try state_decoding.eta.decode(f.reader());
                },
                7 => {
                    entry_span.debug("Decoding iota component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.iota = try state_decoding.iota.decode(allocator, params.validators_count, f.reader());
                },
                8 => {
                    entry_span.debug("Decoding kappa component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.kappa = try state_decoding.kappa.decode(allocator, params.validators_count, f.reader());
                },
                9 => {
                    entry_span.debug("Decoding lambda component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.lambda = try state_decoding.lambda.decode(allocator, params.validators_count, f.reader());
                },
                10 => {
                    entry_span.debug("Decoding rho component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.rho = try state_decoding.rho.decode(params, allocator, f.reader());
                },
                11 => {
                    entry_span.debug("Decoding tau component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.tau = try state_decoding.tau.decode(f.reader());
                    std.debug.print("tau: {d}", .{jam_state.tau.?});
                },
                12 => {
                    entry_span.debug("Decoding chi component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.chi = try state_decoding.chi.decode(allocator, f.reader());
                },
                13 => {
                    entry_span.debug("Decoding pi component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.pi = try state_decoding.pi.decode(params.validators_count, f.reader(), allocator);
                },
                14 => {
                    entry_span.debug("Decoding theta component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.theta = try state_decoding.theta.decode(params.epoch_length, allocator, f.reader());
                },
                15 => {
                    entry_span.debug("Decoding xi component (id={d})", .{key[0]});
                    var f = fbs(value);
                    jam_state.xi = try state_decoding.xi.decode(params.epoch_length, allocator, f.reader());
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

                try delta_reconstruction.reconstructServiceAccountBase(allocator, &jam_state.delta.?, key, value);
            },
            .delta_storage => {
                var storage_span = entry_span.child(.process_delta_storage);
                defer storage_span.deinit();
                storage_span.debug("Processing delta storage entry", .{});

                try delta_reconstruction.reconstructStorageEntry(allocator, &jam_state.delta.?, key, value);
            },
            .delta_preimage => {
                var preimage_span = entry_span.child(.process_delta_preimage);
                defer preimage_span.deinit();
                preimage_span.debug("Processing delta preimage entry", .{});

                try delta_reconstruction.reconstructPreimageEntry(allocator, &jam_state.delta.?, jam_state.tau, key, value);
            },
            .delta_lookup => {
                var lookup_span = entry_span.child(.process_delta_lookup);
                defer lookup_span.deinit();
                lookup_span.debug("Processing delta lookup entry", .{});

                // Buffer the lookup entry for later processing after all preimages are loaded
                try preimage_lookup_buffer.append(.{
                    .key = key,
                    .value = value,
                });
                lookup_span.debug("Buffered preimage lookup entry for later processing", .{});
            },
            .unknown => {
                entry_span.err("Invalid key encountered: {any}", .{key});
                return error.InvalidKey;
            },
        }
    }

    // Second pass: Process buffered preimage lookup entries now that all preimages are loaded
    var lookup_span = span.child(.process_lookups);
    defer lookup_span.deinit();

    lookup_span.debug("Processing {d} buffered preimage lookup entries", .{preimage_lookup_buffer.items.len});

    for (preimage_lookup_buffer.items) |buffered| {
        try delta_reconstruction.reconstructPreimageLookupEntry(
            allocator,
            &jam_state.delta.?,
            buffered.key,
            buffered.value,
        );
    }

    span.debug("State reconstruction completed successfully. Processed {d} entries total, including {d} preimage lookups", .{
        entry_count,
        preimage_lookup_buffer.items.len,
    });

    return jam_state;
}
