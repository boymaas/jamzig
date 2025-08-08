/// Theta (θ) decoder for v0.6.7
/// Decodes the accumulation outputs (lastaccout)
const std = @import("std");
const types = @import("../types.zig");
const codec = @import("../codec.zig");

const accumulation_outputs = @import("../accumulation_outputs.zig");
const Theta = accumulation_outputs.Theta;
const AccumulationOutput = accumulation_outputs.AccumulationOutput;

const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const trace = @import("../tracing.zig").scoped(.codec);

/// Decode Theta (θ) - the most recent accumulation outputs
/// As per v0.6.7: θ ∈ seq{(N_S, H)}
pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Theta {
    const span = trace.span(.decode);
    defer span.deinit();
    span.debug("Starting theta (accumulation outputs) decoding", .{});

    try context.push(.{ .component = "theta" });
    defer context.pop();

    // Read number of outputs
    try context.push(.{ .field = "outputs_count" });
    const outputs_len = codec.readInteger(reader) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read outputs count: {s}", .{@errorName(err)});
    };
    span.debug("Theta contains {d} outputs", .{outputs_len});
    context.pop();

    var theta = Theta.init(allocator);
    errdefer theta.deinit();

    // Read each output
    try context.push(.{ .field = "outputs" });
    var i: usize = 0;
    while (i < outputs_len) : (i += 1) {
        try context.push(.{ .array_index = i });

        const output_span = span.child(.output);
        defer output_span.deinit();
        output_span.debug("Decoding output {d} of {d}", .{ i + 1, outputs_len });

        // Read service_id (4 bytes little-endian)
        try context.push(.{ .field = "service_id" });
        const service_id = reader.readInt(u32, .little) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read service_id: {s}", .{@errorName(err)});
        };
        output_span.trace("Read service_id: {d}", .{service_id});
        context.pop();

        // Read hash (32 bytes)
        try context.push(.{ .field = "hash" });
        var hash: types.Hash = undefined;
        reader.readNoEof(&hash) catch |err| {
            return context.makeError(error.EndOfStream, "failed to read hash: {s}", .{@errorName(err)});
        };
        output_span.trace("Read hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});
        context.pop();

        // Add to theta
        try theta.addOutput(service_id, hash);
        output_span.debug("Added output for service {d}", .{service_id});

        context.pop(); // array_index
    }
    context.pop(); // outputs

    span.debug("Successfully decoded theta with {d} outputs", .{outputs_len});
    return theta;
}

