/// Theta (θ) component for JAM v0.6.7
/// Stores the most recent accumulation outputs (lastaccout)
/// This is a new component in v0.6.7, repurposing the theta symbol
const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

/// Accumulation output entry: (service_id, hash)
pub const AccumulationOutput = struct {
    service_id: types.ServiceId,
    hash: types.Hash,
};

/// Theta: The most recent Accumulation outputs
/// As per v0.6.7: θ ∈ seq{(N_S, H)}
pub const Theta = struct {
    /// Sequence of service/hash pairs from the last accumulation
    outputs: std.ArrayList(AccumulationOutput),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Theta {
        return .{
            .outputs = std.ArrayList(AccumulationOutput).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Theta) void {
        self.outputs.deinit();
        self.* = undefined;
    }

    pub fn deepClone(self: *const Theta, allocator: Allocator) !Theta {
        var clone = Theta.init(allocator);
        errdefer clone.deinit();

        try clone.outputs.appendSlice(self.outputs.items);
        return clone;
    }

    /// Clear and set new accumulation outputs
    pub fn setOutputs(self: *Theta, new_outputs: []const AccumulationOutput) !void {
        self.outputs.clearRetainingCapacity();
        try self.outputs.appendSlice(new_outputs);
    }

    /// Add a single accumulation output
    pub fn addOutput(self: *Theta, service_id: types.ServiceId, hash: types.Hash) !void {
        try self.outputs.append(.{
            .service_id = service_id,
            .hash = hash,
        });
    }

    /// Get outputs as a slice
    pub fn getOutputs(self: *const Theta) []const AccumulationOutput {
        return self.outputs.items;
    }

    /// Check if a service has an accumulation output
    pub fn hasOutput(self: *const Theta, service_id: types.ServiceId) ?types.Hash {
        for (self.outputs.items) |output| {
            if (output.service_id == service_id) {
                return output.hash;
            }
        }
        return null;
    }

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Theta{{ {} outputs }}", .{self.outputs.items.len});
    }
};

