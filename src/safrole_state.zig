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
        try jw.beginObject();

        try jw.objectField("k");
        try jw.write(self.k);

        try jw.objectField("z");
        try jw.write(self.z);

        try jw.objectField("s");
        try jw.beginObject();
        switch (self.s) {
            .tickets => |tickets| {
                try jw.objectField("tickets");
                try jw.write(tickets);
            },
            .keys => |keys| {
                try jw.objectField("keys");
                try jw.write(keys);
            },
        }
        try jw.endObject();

        try jw.objectField("a");
        try jw.write(self.a);

        try jw.endObject();
    }

    pub fn deinit(self: *Gamma, allocator: std.mem.Allocator) void {
        allocator.free(self.k);
        allocator.free(self.s.tickets);
        allocator.free(self.a);
    }
};
