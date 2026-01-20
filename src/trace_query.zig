const std = @import("std");
const jam_params = @import("jam_params.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const state_dictionary = @import("state_dictionary.zig");
const reconstruct = @import("state_dictionary/reconstruct.zig");
const w3f_loader = @import("trace_runner/parsers/w3f/state_transition.zig");
const generic = @import("trace_runner/generic.zig");

const params = jam_params.TINY_PARAMS;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 3) {
        try printUsage();
        std.process.exit(1);
    }

    const trace_path = args[1];
    const query = args[2];
    const state_selector = if (args.len > 3) args[3] else "pre_state";

    // Load using existing binary loader
    var transition = w3f_loader.loadTestVector(params, allocator, trace_path) catch |err| {
        std.debug.print("Error loading trace: {s}\n  Path: {s}\n", .{ @errorName(err), trace_path });
        std.process.exit(1);
    };
    defer transition.deinit(allocator);

    // Route query
    if (std.mem.startsWith(u8, query, "block.")) {
        try queryBlock(&transition.block, query["block.".len..]);
    } else {
        try queryState(allocator, &transition, query, state_selector);
    }
}

fn queryBlock(block: *const types.Block, field: []const u8) !void {
    if (std.mem.startsWith(u8, field, "header.")) {
        const header_field = field["header.".len..];
        try queryHeader(&block.header, header_field);
    } else if (std.mem.eql(u8, field, "header")) {
        try printHeader(&block.header);
    } else {
        std.debug.print("Unknown block field: {s}\n", .{field});
        std.debug.print("Available: header, header.slot, header.author_index, etc.\n", .{});
        std.process.exit(1);
    }
}

fn queryHeader(header: *const types.Header, field: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (std.mem.eql(u8, field, "slot")) {
        try stdout.print("{d}\n", .{header.slot});
    } else if (std.mem.eql(u8, field, "author_index")) {
        try stdout.print("{d}\n", .{header.author_index});
    } else if (std.mem.eql(u8, field, "parent")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.parent)});
    } else if (std.mem.eql(u8, field, "parent_state_root")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.parent_state_root)});
    } else if (std.mem.eql(u8, field, "extrinsic_hash")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.extrinsic_hash)});
    } else if (std.mem.eql(u8, field, "seal")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.seal)});
    } else if (std.mem.eql(u8, field, "entropy_source")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.entropy_source)});
    } else {
        std.debug.print("Unknown header field: {s}\n", .{field});
        std.debug.print("Available: slot, author_index, parent, parent_state_root, extrinsic_hash, seal, entropy_source\n", .{});
        std.process.exit(1);
    }
}

fn printHeader(header: *const types.Header) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("slot: {d}\n", .{header.slot});
    try stdout.print("author_index: {d}\n", .{header.author_index});
    try stdout.print("parent: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.parent)});
    try stdout.print("parent_state_root: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.parent_state_root)});
    try stdout.print("extrinsic_hash: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.extrinsic_hash)});
}

fn queryState(
    allocator: std.mem.Allocator,
    transition: *const generic.StateTransition,
    query: []const u8,
    state_selector: []const u8,
) !void {
    // Get MerklizationDictionary for selected state
    var dict = if (std.mem.eql(u8, state_selector, "post_state"))
        try transition.postStateAsMerklizationDict(allocator)
    else
        try transition.preStateAsMerklizationDict(allocator);
    defer dict.deinit();

    // Reconstruct JamState
    var jam_state = try reconstruct.reconstructState(params, allocator, &dict);
    defer jam_state.deinit(allocator);

    // Query the state
    try printStateField(&jam_state, query);
}

fn printStateField(jam_state: *const state.JamState(params), query: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Parse query: "field" or "field.subfield" or "field.N.subfield"
    var iter = std.mem.splitScalar(u8, query, '.');
    const field = iter.next() orelse {
        std.debug.print("Empty query\n", .{});
        return;
    };

    if (std.mem.eql(u8, field, "tau")) {
        if (jam_state.tau) |tau| {
            try stdout.print("{d}\n", .{tau});
        } else {
            try stdout.print("null\n", .{});
        }
    } else if (std.mem.eql(u8, field, "eta")) {
        if (jam_state.eta) |eta| {
            const subfield = iter.rest();
            if (subfield.len > 0) {
                const idx = std.fmt.parseInt(usize, subfield, 10) catch {
                    std.debug.print("Invalid eta index: {s}\n", .{subfield});
                    return;
                };
                if (idx >= 4) {
                    std.debug.print("eta index out of range (0-3)\n", .{});
                    return;
                }
                try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&eta[idx])});
            } else {
                for (0..4) |i| {
                    try stdout.print("eta[{d}]: 0x{s}\n", .{ i, std.fmt.fmtSliceHexLower(&eta[i]) });
                }
            }
        } else {
            try stdout.print("null\n", .{});
        }
    } else if (std.mem.eql(u8, field, "gamma")) {
        if (jam_state.gamma) |gamma| {
            const subfield = iter.rest();
            if (std.mem.eql(u8, subfield, "s") or subfield.len == 0) {
                switch (gamma.s) {
                    .tickets => |tickets| {
                        try stdout.print("type: tickets\n", .{});
                        try stdout.print("count: {d}\n", .{tickets.len});
                    },
                    .keys => |keys| {
                        try stdout.print("type: fallback (keys)\n", .{});
                        try stdout.print("count: {d}\n", .{keys.len});
                    },
                }
            } else if (std.mem.eql(u8, subfield, "k")) {
                try stdout.print("pending validators: {d}\n", .{gamma.k.len()});
            } else if (std.mem.eql(u8, subfield, "a")) {
                try stdout.print("ticket accumulator: {d}\n", .{gamma.a.len});
            } else if (std.mem.eql(u8, subfield, "z")) {
                try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&gamma.z)});
            }
        } else {
            try stdout.print("null\n", .{});
        }
    } else if (std.mem.eql(u8, field, "kappa")) {
        if (jam_state.kappa) |kappa| {
            const subfield = iter.rest();
            if (subfield.len > 0) {
                try printValidatorField(kappa.validators, subfield);
            } else {
                try stdout.print("validators: {d}\n", .{kappa.len()});
                for (kappa.validators, 0..) |v, i| {
                    try stdout.print("[{d}] bandersnatch: 0x{s}...\n", .{ i, std.fmt.fmtSliceHexLower(v.bandersnatch[0..8]) });
                }
            }
        } else {
            try stdout.print("null\n", .{});
        }
    } else if (std.mem.eql(u8, field, "rho")) {
        if (jam_state.rho) |rho| {
            var active: usize = 0;
            for (rho.reports, 0..) |entry, i| {
                if (entry) |e| {
                    active += 1;
                    try stdout.print("core[{d}]: timeout={d}, hash=0x{s}...\n", .{
                        i,
                        e.assignment.timeout,
                        std.fmt.fmtSliceHexLower(e.assignment.report.package_spec.hash[0..8]),
                    });
                }
            }
            if (active == 0) try stdout.print("(no active reports)\n", .{});
        } else {
            try stdout.print("null\n", .{});
        }
    } else if (std.mem.eql(u8, field, "beta")) {
        if (jam_state.beta) |beta| {
            try stdout.print("recent blocks: {d}\n", .{beta.recent_history.blocks.items.len});
            for (beta.recent_history.blocks.items, 0..) |b, i| {
                try stdout.print("[{d}] hash: 0x{s}...\n", .{ i, std.fmt.fmtSliceHexLower(b.header_hash[0..8]) });
            }
        } else {
            try stdout.print("null\n", .{});
        }
    } else {
        std.debug.print("Unknown field: {s}\n", .{field});
        try printAvailableFields();
        std.process.exit(1);
    }
}

fn printValidatorField(validators: []const types.ValidatorData, subfield: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Parse "N" or "N.field"
    var sub_iter = std.mem.splitScalar(u8, subfield, '.');
    const idx_str = sub_iter.next() orelse return;
    const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
        std.debug.print("Invalid validator index: {s}\n", .{idx_str});
        return;
    };

    if (idx >= validators.len) {
        std.debug.print("Validator index {d} out of range (max {d})\n", .{ idx, validators.len - 1 });
        return;
    }

    const v = validators[idx];
    const field = sub_iter.rest();

    if (std.mem.eql(u8, field, "bandersnatch")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.bandersnatch)});
    } else if (std.mem.eql(u8, field, "ed25519")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.ed25519)});
    } else if (std.mem.eql(u8, field, "bls")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.bls)});
    } else if (std.mem.eql(u8, field, "metadata")) {
        try stdout.print("0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.metadata)});
    } else if (field.len == 0) {
        try stdout.print("bandersnatch: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.bandersnatch)});
        try stdout.print("ed25519: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.ed25519)});
        try stdout.print("bls: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.bls)});
        try stdout.print("metadata: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&v.metadata)});
    } else {
        std.debug.print("Unknown validator field: {s}\n", .{field});
        std.debug.print("Available: bandersnatch, ed25519, bls, metadata\n", .{});
    }
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Usage: trace-query <trace_file.bin> <query> [pre_state|post_state]
        \\
        \\Arguments:
        \\  trace_file.bin   Full path to the trace binary file
        \\  query            State or block field to query
        \\  pre_state|post_state  Which state to query (default: pre_state)
        \\
        \\Examples:
        \\  # Query specific trace file
        \\  trace-query src/w3f-conformance/fuzz-reports/0.7.1/traces/1761665520/00000008.bin tau
        \\  trace-query path/to/trace.bin gamma.s
        \\  trace-query path/to/trace.bin kappa.0.bandersnatch
        \\  trace-query path/to/trace.bin eta.2
        \\  trace-query path/to/trace.bin block.header.slot
        \\  trace-query path/to/trace.bin tau post_state
        \\
    , .{});
}

fn printAvailableFields() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Available state fields:
        \\  tau       - Current timeslot
        \\  eta       - Entropy (eta.0, eta.1, eta.2, eta.3)
        \\  gamma     - Safrole state (gamma.s, gamma.k, gamma.a, gamma.z)
        \\  kappa     - Validators (kappa.N.bandersnatch, etc.)
        \\  rho       - Pending reports
        \\  beta      - Recent blocks
        \\
        \\Block fields:
        \\  block.header.slot, block.header.author_index, etc.
        \\
    , .{});
}
