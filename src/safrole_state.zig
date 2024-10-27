const std = @import("std");
const types = @import("types.zig");
const safrole_types = @import("safrole/types.zig");

// TODO: move this to a seperate file
pub const Gamma = struct {
    k: safrole_types.GammaK,
    z: safrole_types.GammaZ,
    s: safrole_types.GammaS,
    a: safrole_types.GammaA,

    pub fn init(allocator: std.mem.Allocator) !Gamma {
        return Gamma{
            .k = try allocator.alloc(safrole_types.ValidatorData, 0),
            .z = std.mem.zeroes(safrole_types.BandersnatchVrfRoot),
            .s = .{ .tickets = try allocator.alloc(safrole_types.TicketBody, 0) },
            .a = try allocator.alloc(safrole_types.TicketBody, 0),
        };
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try @import("state_json/safrole_state.zig").jsonStringify(self, jw);
    }

    pub fn deinit(self: *Gamma, allocator: std.mem.Allocator) void {
        allocator.free(self.k);
        allocator.free(self.s.tickets);
        allocator.free(self.a);
    }
};
