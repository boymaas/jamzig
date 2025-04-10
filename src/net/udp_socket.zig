const std = @import("std");
const posix = std.posix;

pub const UdpSocket = struct {
    socket: posix.socket_t,
    bound_address: ?std.net.Address = null,

    const Datagram = struct {
        bytes_read: []const u8,
        source: std.net.Address,
    };

    /// Create a dual-stack IPv6 socket that can handle both IPv6 and IPv4 traffic
    pub fn init() !UdpSocket {
        // Create an IPv6 socket
        const socket = try posix.socket(posix.AF.INET6, posix.SOCK.DGRAM, 0);

        // Explicitly ensure IPv4 compatibility by disabling IPV6_V6ONLY
        _ = posix.setsockopt(
            socket,
            posix.IPPROTO.IPV6,
            std.os.linux.IPV6.V6ONLY,
            &std.mem.toBytes(@as(c_int, 0)),
        ) catch |err| {
            // If setting the option fails, we'll still continue
            // as many systems default to dual-stack
            std.debug.print("Warning: Failed to set IPV6_V6ONLY option: {}\n", .{err});
        };

        return UdpSocket{ .socket = socket };
    }

    pub fn deinit(self: *UdpSocket) void {
        posix.close(self.socket);
    }

    /// Bind the socket to address:port
    pub fn bind(self: *UdpSocket, addr: []const u8, port: u16) !void {
        var address = try std.net.Address.parseIp(addr, port);

        // If this is an IPv4 address, convert it to an IPv4-mapped IPv6 address
        if (address.any.family == posix.AF.INET) {
            // Extract IPv4 address and port
            const ipv4_addr = address.in.sa.addr;
            const ipv4_port = address.in.sa.port;

            // Create IPv6 mapped address (::ffff:a.b.c.d format)
            const ipv6_addr = std.net.Address.initIp6(
                [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff } ++ @as(*const [4]u8, @ptrCast(&ipv4_addr)).*,
                ipv4_port,
                0,
                0,
            );
            address = ipv6_addr;
        }

        // Bind the socket to the address
        try posix.bind(
            self.socket,
            &address.any,
            address.getOsSockLen(),
        );

        var saddr: posix.sockaddr align(4) = undefined;
        var saddrlen: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(
            self.socket,
            @ptrCast(&saddr),
            &saddrlen,
        );
        self.bound_address = std.net.Address.initPosix(&saddr);
    }

    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !Datagram {
        var src_addr: posix.sockaddr align(4) = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);
        const bytes_read = try posix.recvfrom(
            self.socket,
            buffer,
            0,
            @ptrCast(&src_addr),
            &addrlen,
        );

        // Convert from POSIX sockaddr to Zig's Address type
        const source_addr = std.net.Address.initPosix(&src_addr);

        return .{
            .bytes_read = buffer[0..bytes_read],
            .source = source_addr,
        };
    }

    /// Send data to a specific address
    pub fn sendTo(self: *UdpSocket, data: []const u8, addr: std.net.Address) !usize {
        return posix.sendto(
            self.socket,
            data,
            0,
            &addr.any,
            addr.getOsSockLen(),
        );
    }

    /// Send data to a specific address
    pub fn sendToSockAddr(self: *UdpSocket, data: []const u8, sockaddr: *align(4) const posix.sockaddr) !usize {
        return posix.sendto(
            self.socket,
            data,
            0,
            @ptrCast(&sockaddr),
            @sizeOf(@TypeOf(sockaddr)),
        );
    }

    /// Retrieves the end point to which the socket is bound.
    pub fn getLocalAddress(self: *@This()) !std.net.Address {
        var addr: std.posix.sockaddr align(4) = undefined;
        var size: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        try std.posix.getsockname(self.socket, &addr, &size);
        return std.net.Address.initPosix(&addr);
    }

    /// Check if an address is an IPv4-mapped IPv6 address
    pub fn isIPv4Mapped(addr: std.net.Address) bool {
        if (addr.any.family != posix.AF.INET6) return false;

        const in6_addr = addr.in6.sa.sin6_addr;

        // Check first 10 bytes are 0
        for (in6_addr.s6_addr[0..10]) |byte| {
            if (byte != 0) return false;
        }

        // Check next 2 bytes are 0xFF
        if (in6_addr.s6_addr[10] != 0xFF or in6_addr.s6_addr[11] != 0xFF) {
            return false;
        }

        return true;
    }
};

const testing = std.testing;

// Simple test that sends "JamZig" over UDP
test UdpSocket {
    // Create receiver socket on a system
    // assigned port
    var receiver = try UdpSocket.init();
    defer receiver.deinit();
    try receiver.bind("::", 0);
    std.debug.print("Receiver bound on: {}\n", .{receiver.bound_address.?});

    // Create sender socket
    var sender = try UdpSocket.init();
    defer sender.deinit();

    // The message to send
    const message = "JamZig";

    // Send the message
    const dest_addr = receiver.bound_address;
    const bytes_sent = try sender.sendTo(message, dest_addr.?);
    std.debug.print("Sent {d} bytes\n", .{bytes_sent});

    // Receive buffer
    var buffer: [128]u8 = undefined;

    // Receive the message
    const datagram = try receiver.recvFrom(&buffer);
    std.debug.print("Received: '{s}'\n", .{datagram.bytes_read});
    std.debug.print("Received from: '{}'\n", .{datagram.source});

    // Verify the data
    try std.testing.expectEqualStrings(message, datagram.bytes_read);

    // Test IPv4 functionality
    std.debug.print("Testing IPv4 address...\n", .{});
    try receiver.bind("127.0.0.1", 0);
    std.debug.print("IPv4 receiver bound on: {}\n", .{receiver.bound_address.?});

    // Check if it's an IPv4-mapped address when we bound to 127.0.0.1
    if (UdpSocket.isIPv4Mapped(receiver.bound_address.?)) {
        std.debug.print("Detected IPv4-mapped address\n", .{});
    }
}
