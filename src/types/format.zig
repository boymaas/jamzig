const std = @import("std");
const types = @import("../types.zig");

pub fn formatExtrinsic(extrinsic: types.Extrinsic, writer: anytype) !void {
    try writer.print("Extrinsic {{\n", .{});

    // Format tickets
    try writer.print("  tickets: [\n", .{});
    for (extrinsic.tickets.data) |ticket| {
        try writer.print("    {{ attempt: {d}, signature: 0x{s} }}\n", .{ ticket.attempt, std.fmt.fmtSliceHexLower(&ticket.signature) });
    }
    try writer.print("  ]\n", .{});

    // Format disputes
    try writer.print("  disputes: {{\n", .{});
    try writer.print("    verdicts: [\n", .{});
    for (extrinsic.disputes.verdicts) |verdict| {
        try writer.print("      {{ target: 0x{s}, age: {d}, votes: [\n", .{ std.fmt.fmtSliceHexLower(&verdict.target), verdict.age });
        for (verdict.votes) |vote| {
            try writer.print("        {{ vote: {}, index: {d}, signature: 0x{s} }}\n", .{ vote.vote, vote.index, std.fmt.fmtSliceHexLower(&vote.signature) });
        }
        try writer.print("      ] }}\n", .{});
    }
    try writer.print("    ]\n", .{});

    try writer.print("    culprits: [\n", .{});
    for (extrinsic.disputes.culprits) |culprit| {
        try writer.print("      {{ target: 0x{s}, key: 0x{s}, signature: 0x{s} }}\n", .{ std.fmt.fmtSliceHexLower(&culprit.target), std.fmt.fmtSliceHexLower(&culprit.key), std.fmt.fmtSliceHexLower(&culprit.signature) });
    }
    try writer.print("    ]\n", .{});

    try writer.print("    faults: [\n", .{});
    for (extrinsic.disputes.faults) |fault| {
        try writer.print("      {{ target: 0x{s}, vote: {}, key: 0x{s}, signature: 0x{s} }}\n", .{ std.fmt.fmtSliceHexLower(&fault.target), fault.vote, std.fmt.fmtSliceHexLower(&fault.key), std.fmt.fmtSliceHexLower(&fault.signature) });
    }
    try writer.print("    ]\n", .{});
    try writer.print("  }}\n", .{});

    // Format preimages
    try writer.print("  preimages: [\n", .{});
    for (extrinsic.preimages.data) |preimage| {
        try writer.print("    {{ requester: {d}, blob: 0x{s} }}\n", .{ preimage.requester, std.fmt.fmtSliceHexLower(preimage.blob) });
    }
    try writer.print("  ]\n", .{});

    // Format assurances
    try writer.print("  assurances: [\n", .{});
    for (extrinsic.assurances.data) |assurance| {
        try writer.print("    {{ anchor: 0x{s}, bitfield: 0x{s}, validator_index: {d}, signature: 0x{s} }}\n", .{ std.fmt.fmtSliceHexLower(&assurance.anchor), std.fmt.fmtSliceHexLower(assurance.bitfield), assurance.validator_index, std.fmt.fmtSliceHexLower(&assurance.signature) });
    }
    try writer.print("  ]\n", .{});

    // Format guarantees
    try writer.print("  guarantees: [\n", .{});
    for (extrinsic.guarantees.data) |guarantee| {
        try writer.print("    {{ report: {{ ... }}, slot: {d}, signatures: [\n", .{guarantee.slot});
        for (guarantee.signatures) |sig| {
            try writer.print("      {{ validator_index: {d}, signature: 0x{s} }}\n", .{ sig.validator_index, std.fmt.fmtSliceHexLower(&sig.signature) });
        }
        try writer.print("    ] }}\n", .{});
    }
    try writer.print("  ]\n", .{});

    try writer.print("}}\n", .{});
}

pub fn formatHeader(header: types.Header, writer: anytype) !void {
    try writer.print("Header {{\n", .{});
    try writer.print("  parent: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.parent)});
    try writer.print("  parent_state_root: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.parent_state_root)});
    try writer.print("  extrinsic_hash: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.extrinsic_hash)});
    try writer.print("  slot: {d}\n", .{header.slot});

    if (header.epoch_mark) |epoch_mark| {
        try writer.print("  epoch_mark: {{\n", .{});
        try writer.print("    entropy: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&epoch_mark.entropy)});
        try writer.print("    validators: [\n", .{});
        for (epoch_mark.validators) |validator| {
            try writer.print("      0x{s}\n", .{std.fmt.fmtSliceHexLower(&validator)});
        }
        try writer.print("    ]\n", .{});
        try writer.print("  }}\n", .{});
    } else {
        try writer.print("  epoch_mark: null\n", .{});
    }

    if (header.tickets_mark) |tickets_mark| {
        try writer.print("  tickets_mark: [\n", .{});
        for (tickets_mark.tickets) |ticket| {
            try writer.print("    {{ id: 0x{s}, attempt: {d} }}\n", .{ std.fmt.fmtSliceHexLower(&ticket.id), ticket.attempt });
        }
        try writer.print("  ]\n", .{});
    } else {
        try writer.print("  tickets_mark: null\n", .{});
    }

    try writer.print("  offenders_mark: [\n", .{});
    for (header.offenders_mark) |offender| {
        try writer.print("    0x{s}\n", .{std.fmt.fmtSliceHexLower(&offender)});
    }
    try writer.print("  ]\n", .{});

    try writer.print("  author_index: {d}\n", .{header.author_index});
    try writer.print("  entropy_source: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.entropy_source)});
    try writer.print("  seal: 0x{s}\n", .{std.fmt.fmtSliceHexLower(&header.seal)});
    try writer.print("}}\n", .{});
}
