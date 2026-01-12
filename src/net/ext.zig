const std = @import("std");
const network = @import("network");

pub fn toSocketAddress(self: network.EndPoint) network.EndPoint.SockAddr {
    return switch (self.address) {
        .ipv4 => |addr| .{
            .ipv4 = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, self.port),
                .addr = @bitCast(addr.value),
                .zero = [_]u8{0} ** 8,
            },
        },
        .ipv6 => |addr| .{
            .ipv6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, self.port),
                .flowinfo = 0,
                .addr = addr.value,
                .scope_id = addr.scope_id,
            },
        },
    };
}
