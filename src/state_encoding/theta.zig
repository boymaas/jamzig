/// Theta (θ) encoder for v0.6.7
/// Encodes the accumulation outputs (lastaccout)
const std = @import("std");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const encoder = @import("../codec/encoder.zig");

const accumulation_outputs = @import("../accumulation_outputs.zig");
const Theta = accumulation_outputs.Theta;
const AccumulationOutput = accumulation_outputs.AccumulationOutput;

const trace = @import("../tracing.zig").scoped(.codec);

/// Encode Theta (θ) - the most recent accumulation outputs
/// As per v0.6.7: θ ∈ seq{(N_S, H)}
/// Format: encode([encode_4(s) || encode(h) for (s, h) in sorted(theta)])
pub fn encode(theta: *const Theta, writer: anytype) !void {
    const span = trace.span(.encode);
    defer span.deinit();
    span.debug("Starting theta (accumulation outputs) encoding", .{});
    
    const outputs = theta.getOutputs();
    
    // First encode the number of outputs
    try codec.writeInteger(outputs.len, writer);
    span.debug("Encoding {d} accumulation outputs", .{outputs.len});
    
    // Sort outputs by service_id for deterministic encoding
    const sorted_outputs = try theta.allocator.alloc(AccumulationOutput, outputs.len);
    defer theta.allocator.free(sorted_outputs);
    @memcpy(sorted_outputs, outputs);
    
    std.sort.insertion(AccumulationOutput, sorted_outputs, {}, struct {
        pub fn lessThan(_: void, a: AccumulationOutput, b: AccumulationOutput) bool {
            return a.service_id < b.service_id;
        }
    }.lessThan);
    
    // Encode each output: service_id (4 bytes) + hash (32 bytes)
    for (sorted_outputs, 0..) |output, i| {
        const output_span = span.child(.output);
        defer output_span.deinit();
        output_span.debug("Encoding output {d}: service_id={d}", .{ i, output.service_id });
        
        // Write service_id as 4 bytes little-endian
        try writer.writeInt(u32, output.service_id, .little);
        
        // Write hash directly (32 bytes)
        try writer.writeAll(&output.hash);
        
        output_span.trace("Encoded service {d} hash: {s}", .{ 
            output.service_id, 
            std.fmt.fmtSliceHexLower(&output.hash) 
        });
    }
    
    span.debug("Completed theta encoding", .{});
}