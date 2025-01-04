const std = @import("std");
const types = @import("types.zig");

// TODO: move this to a seperate file
pub fn Gamma(comptime validators_count: u32, comptime epoch_length: u32) type {
    return struct {
        k: types.GammaK,
        z: types.GammaZ,
        s: types.GammaS,
        a: types.GammaA,

        pub fn init(allocator: std.mem.Allocator) !Gamma(validators_count, epoch_length) {
            return Gamma(validators_count, epoch_length){
                .k = try types.GammaK.init(allocator, validators_count),
                .z = std.mem.zeroes(types.BandersnatchVrfRoot),
                .s = .{ .tickets = try allocator.alloc(types.TicketBody, epoch_length) },
                .a = &[_]types.TicketBody{},
            };
        }

        pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
            try @import("state_json/safrole_state.zig").jsonStringify(
                validators_count,
                epoch_length,
                self,
                jw,
            );
        }

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try @import("state_format/safrole_state.zig").format(validators_count, epoch_length, self, fmt, options, writer);
        }

        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            self.k.deinit(allocator);
            self.s.deinit(allocator);
            allocator.free(self.a);
        }

        pub fn deepClone(self: *const @This(), allocator: std.mem.Allocator) !Gamma(validators_count, epoch_length) {
            return .{
                .k = try self.k.deepClone(allocator),
                .z = self.z,
                .s = try self.s.deepClone(allocator),
                .a = try allocator.dupe(types.TicketBody, self.a),
            };
        }
    };
}
