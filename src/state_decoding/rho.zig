
const std = @import("std");
const testing = std.testing;
const pending_reports = @import("../reports_pending.zig");
const types = @import("../types.zig");
const Rho = pending_reports.Rho;
const codec = @import("../codec.zig");
const createEmptyWorkReport = @import("../tests/fixtures.zig").createEmptyWorkReport;
const jam_params = @import("../jam_params.zig");
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

pub const DecoderParams = struct {
    core_count: u16,

    pub fn fromJamParams(comptime params: anytype) DecoderParams {
        return .{
            .core_count = params.core_count,
        };
    }
};

pub fn decode(
    comptime params: DecoderParams,
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Rho(params.core_count) {
    try context.push(.{ .component = "rho" });
    defer context.pop();

    var rho = Rho(params.core_count).init(allocator);

    try context.push(.{ .field = "reports" });
    for (&rho.reports, 0..) |*maybe_entry, core_index| {
        try context.push(.{ .array_index = core_index });
        
        const exists = reader.readByte() catch |err| {
            return context.makeError(error.EndOfStream, "failed to read existence marker: {s}", .{@errorName(err)});
        };
        
        if (exists == 1) {
            const assignment = codec.deserializeAlloc(
                types.AvailabilityAssignment,
                {},
                allocator,
                reader,
            ) catch |err| {
                return context.makeError(error.EndOfStream, "failed to decode availability assignment: {s}", .{@errorName(err)});
            };

            maybe_entry.* = .{
                .core = @intCast(core_index),
                .assignment = assignment,
            };
        } else if (exists == 0) {
            maybe_entry.* = null;
        } else {
            return context.makeError(error.InvalidExistenceMarker, "invalid existence marker: {}", .{exists});
        }
        
        context.pop();
    }
    context.pop();

    return rho;
}

test "decode rho - empty state" {
    const params = comptime DecoderParams{
        .core_count = 2,
    };

    var context = DecodingContext.init(testing.allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    for (0..params.core_count) |_| {
        try buffer.append(0);
    }

    var fbs = std.io.fixedBufferStream(buffer.items);
    const rho = try decode(params, std.testing.allocator, &context, fbs.reader());

    for (rho.reports) |maybe_entry| {
        try testing.expect(maybe_entry == null);
    }
}

test "decode rho - invalid existence marker" {
    const params = comptime DecoderParams{
        .core_count = 1,
    };

    var context = DecodingContext.init(testing.allocator);
    defer context.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try buffer.append(2);

    var fbs = std.io.fixedBufferStream(buffer.items);
    try testing.expectError(error.InvalidExistenceMarker, decode(
        params,
        std.testing.allocator,
        &context,
        fbs.reader(),
    ));
}

// TODO: test encoding/decoding of the WorkResult and the WorkExecResults
test "decode rho - roundtrip" {
    const encoder = @import("../state_encoding/rho.zig");
    const params = comptime DecoderParams{
        .core_count = 2,
    };
    const full_params = @import("../jam_params.zig").TINY_PARAMS;

    var context = DecodingContext.init(testing.allocator);
    defer context.deinit();

    var original = Rho(params.core_count).init(testing.allocator);

    const hash = [_]u8{1} ** 32;
    const report = createEmptyWorkReport(hash);
    original.setReport(0, .{ .report = report, .timeout = 100 });

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try encoder.encode(full_params, &original, buffer.writer());

    var fbs = std.io.fixedBufferStream(buffer.items);
    const decoded = try decode(params, std.testing.allocator, &context, fbs.reader());

    try testing.expect(decoded.reports[0] != null);
    const entry = decoded.reports[0].?;
    try testing.expectEqual(@as(u32, 100), entry.assignment.timeout);

    try testing.expect(decoded.reports[1] == null);
}
