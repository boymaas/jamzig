const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

pub const AccumulationOutput = struct {
    service_id: types.ServiceId,
    hash: types.Hash,
};

pub const Theta = struct {
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

    pub fn setOutputs(self: *Theta, new_outputs: []const AccumulationOutput) !void {
        self.outputs.clearRetainingCapacity();
        try self.outputs.appendSlice(new_outputs);
    }

    pub fn addOutput(self: *Theta, service_id: types.ServiceId, hash: types.Hash) !void {
        try self.outputs.append(.{
            .service_id = service_id,
            .hash = hash,
        });
    }

    pub fn getOutputs(self: *const Theta) []const AccumulationOutput {
        return self.outputs.items;
    }

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

