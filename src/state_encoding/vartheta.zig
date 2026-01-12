const std = @import("std");
const types = @import("../types.zig");
const WorkReport = types.WorkReport;
const encoder = @import("../codec/encoder.zig");
const codec = @import("../codec.zig");
const sort = std.sort;

const reports_ready = @import("../reports_ready.zig");
const VarTheta = reports_ready.Theta; // Still using Theta type from reports_ready

const makeLessThanSliceOfFn = @import("../utils/sort.zig").makeLessThanSliceOfFn;
const lessThanSliceOfHashes = makeLessThanSliceOfFn(types.Hash);

const trace = @import("tracing").scoped(.codec);

pub fn encode(vartheta: anytype, writer: anytype) !void {
    const span = trace.span(@src(), .encode);
    defer span.deinit();
    span.debug("Starting vartheta encoding", .{});

    for (vartheta.entries, 0..) |slot_entry, i| {
        const entry_span = span.child(@src(), .slot_entry);
        defer entry_span.deinit();
        entry_span.debug("Processing slot entry {d}", .{i});

        try codec.writeInteger(slot_entry.items.len, writer);
        entry_span.debug("Wrote {d} slot entries", .{slot_entry.items.len});

        for (slot_entry.items, 0..) |entry, j| {
            const item_span = entry_span.child(@src(), .entry_item);
            defer item_span.deinit();
            item_span.debug("Encoding entry {d} of {d}", .{ j + 1, slot_entry.items.len });
            try encodeEntry(vartheta.allocator, entry, writer);
        }
    }
    span.debug("Completed theta encoding", .{});
}

pub fn encodeSlotEntry(allocator: std.mem.Allocator, slot_entries: reports_ready.TimeslotEntries, writer: anytype) !void {
    const span = trace.span(@src(), .encode_slot_entry);
    defer span.deinit();
    span.debug("Starting slot entries encoding", .{});

    try writer.writeAll(encoder.encodeInteger(slot_entries.items.len).as_slice());
    span.debug("Wrote slot entries count: {d}", .{slot_entries.items.len});

    for (slot_entries.items, 0..) |entry, i| {
        const entry_span = span.child(@src(), .entry);
        defer entry_span.deinit();
        entry_span.debug("Encoding entry {d} of {d}", .{ i + 1, slot_entries.items.len });
        try encodeEntry(allocator, entry, writer);
    }
    span.debug("Completed slot entries encoding", .{});
}

pub fn encodeEntry(allocator: std.mem.Allocator, entry: reports_ready.WorkReportAndDeps, writer: anytype) !void {
    const span = trace.span(@src(), .encode_entry);
    defer span.deinit();
    span.debug("Starting entry encoding", .{});

    try codec.serialize(WorkReport, {}, writer, entry.work_report);
    span.debug("Encoded work report", .{});
    const dependency_count = entry.dependencies.count();
    try codec.writeInteger(dependency_count, writer);
    span.debug("Writing {d} dependencies", .{dependency_count});

    const keys = try allocator.dupe(types.WorkPackageHash, entry.dependencies.keys());
    defer allocator.free(keys);

    sort.insertion([32]u8, keys, {}, lessThanSliceOfHashes);
    span.debug("Sorted dependency hashes", .{});

    for (keys, 0..) |hash, i| {
        const hash_span = span.child(@src(), .hash);
        defer hash_span.deinit();
        hash_span.trace("Writing hash {d} of {d}: {s}", .{ i + 1, keys.len, std.fmt.fmtSliceHexLower(&hash) });
        try writer.writeAll(&hash);
    }
    span.debug("Completed entry encoding", .{});
}
