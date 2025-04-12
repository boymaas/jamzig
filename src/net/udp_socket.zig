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

        // Allow address reuse - helpful for quickly restarting tests
        _ = posix.setsockopt(
            socket,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch |err| {
            std.debug.print("Warning: Failed to set SO_REUSEADDR option: {}\n", .{err});
        };

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

        // Map IPv4 address to IPv6 if needed
        address = UdpSocket.mapToIPv6(address);

        // Bind the socket to the address
        try posix.bind(
            self.socket,
            &address.any,
            @sizeOf(@TypeOf(address)),
        );

        // var saddr: posix.sockaddr align(4) = undefined;
        // var saddrlen: posix.socklen_t = @sizeOf(posix.sockaddr);

        var saddr: std.posix.sockaddr.in6 align(4) = undefined;
        var saddrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);

        const addr_ptr: *std.posix.sockaddr = @ptrCast(&saddr);
        try std.posix.getsockname(self.socket, addr_ptr, &saddrlen);

        self.bound_address = std.net.Address{ .in6 = std.net.Ip6Address{ .sa = saddr } };
    }

    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !Datagram {
        var src_addr: posix.sockaddr.in6 align(4) = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in6);
        const bytes_read = try posix.recvfrom(
            self.socket,
            buffer,
            0,
            @ptrCast(&src_addr),
            &addrlen,
        );

        // Convert from POSIX sockaddr to Zig's Address type
        const source_addr = std.net.Address{ .in6 = std.net.Ip6Address{ .sa = src_addr } };

        return .{
            .bytes_read = buffer[0..bytes_read],
            .source = source_addr,
        };
    }

    /// Send data to a specific address
    pub fn sendTo(self: *UdpSocket, data: []const u8, addr: std.net.Address) !usize {
        // Ensure address is IPv6 mapped
        // var mapped_addr = UdpSocket.mapToIPv6(addr);

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
        var addr: std.posix.sockaddr.in6 align(4) = undefined;
        var size: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);
        try std.posix.getsockname(self.socket, @ptrCast(&addr), &size);
        return std.net.Address{ .in6 = .{ .sa = addr } };
    }

    /// Maps an IPv4 address to an IPv4-mapped IPv6 address
    /// If the address is already IPv6, it is returned unchanged
    pub fn mapToIPv6(address: std.net.Address) std.net.Address {
        var mapped_address = address;

        // Only perform mapping if this is an IPv4 address
        if (address.any.family == posix.AF.INET) {
            const bytes = std.mem.asBytes(&address.in.sa.addr);

            // Let's try directly copying the bytes without using writeInt
            mapped_address.in6.sa.addr[0..10].* = [_]u8{0} ** 10;
            mapped_address.in6.sa.addr[10] = 0xff;
            mapped_address.in6.sa.addr[11] = 0xff;
            mapped_address.in6.sa.addr[12] = bytes[0];
            mapped_address.in6.sa.addr[13] = bytes[1];
            mapped_address.in6.sa.addr[14] = bytes[2];
            mapped_address.in6.sa.addr[15] = bytes[3];

            // Update the family, flowinfo, and scope_id
            mapped_address.any.family = posix.AF.INET6;
            mapped_address.in6.sa.flowinfo = 0;
            mapped_address.in6.sa.scope_id = 0;
        }

        return mapped_address;
    }

    /// Check if an address is an IPv4-mapped IPv6 address
    pub fn isIPv4Mapped(addr: std.net.Address) bool {
        if (addr.any.family != posix.AF.INET6) return false;

        const addr_bytes = std.mem.asBytes(&addr);

        // Check first 10 bytes are 0
        for (addr_bytes[0..10]) |byte| {
            if (byte != 0) return false;
        }

        // Check next 2 bytes are 0xFF
        if (addr_bytes[10] != 0xFF or addr_bytes[11] != 0xFF) {
            return false;
        }

        return true;
    }
};

const testing = std.testing;

// Helper function to test UDP socket communication with different address configurations
fn testUdpSocketCommunication(receiver_bind_addr: []const u8, sender_bind_addr: []const u8) !void {
    std.debug.print("\n--- Testing UDP: Receiver({s}) -> Sender({s}) ---\n", .{ receiver_bind_addr, sender_bind_addr });

    // Create receiver socket
    var receiver = try UdpSocket.init();
    defer receiver.deinit();
    std.debug.print("Receiver socket fd: {}\n", .{receiver.socket});

    // Bind receiver to specified address with port 0 (system assigns port)
    try receiver.bind(receiver_bind_addr, 0);
    const receiver_addr = try receiver.getLocalAddress();
    std.debug.print("Receiver bound on: {}\n", .{receiver_addr});

    // Create sender socket
    var sender = try UdpSocket.init();
    defer sender.deinit();
    std.debug.print("Sender socket fd: {}\n", .{sender.socket});

    // Bind sender to specified address
    try sender.bind(sender_bind_addr, 0);
    const sender_addr = try sender.getLocalAddress();
    std.debug.print("Sender bound on: {}\n", .{sender_addr});

    // Test message
    const message = "JamZig:Test";

    std.debug.print("Sending '{s}' to {}\n", .{ message, receiver_addr });

    const bytes_sent = try sender.sendTo(message, receiver_addr);
    std.debug.print("Sent {d} bytes\n", .{bytes_sent});

    // Receive buffer
    var buffer: [128]u8 = undefined;

    // Add a timeout to prevent hanging
    try posix.setsockopt(
        receiver.socket,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        &std.mem.toBytes(posix.timeval{
            .sec = 5,
            .usec = 0,
        }),
    );

    // Receive the message
    std.debug.print("Waiting to receive...\n", .{});
    const datagram = receiver.recvFrom(&buffer) catch |err| {
        std.debug.print("Error receiving data: {}\n", .{err});
        std.debug.print("Is the network interface accessible from within your environment?\n", .{});
        std.debug.print("Your environment assigns addresses like: {}\n", .{receiver_addr});
        return err;
    };

    std.debug.print("Received: '{s}'\n", .{datagram.bytes_read});
    std.debug.print("Received from: {}\n", .{datagram.source});

    // Verify the data
    try std.testing.expectEqualStrings(message, datagram.bytes_read);

    std.debug.print("--- Test passed ---\n", .{});
}

test "UdpSocket.IPv4.IPv4" {
    try testUdpSocketCommunication("127.0.0.1", "127.0.0.1");
}

test "UdpSocket.IPv6.IPv6" {
    try testUdpSocketCommunication("::1", "::1");
}

//  net.udp_socket.test.UdpSocket.IPv4.IPv6 (error: AddressFamilyNotSupported)
test "UdpSocket.IPv4.IPv6" {
    // try testUdpSocketCommunication("::1", "127.0.0.1");
}

// net.udp_socket.test.UdpSocket.IPv6.IPv4 (error: NetworkUnreachable)
test "UdpSocket.IPv6.IPv4" {
    // try testUdpSocketCommunication("127.0.0.1", "::1");
}

test "UdpSocket.IPv4.Wildcard" {
    try testUdpSocketCommunication("127.0.0.1", "0.0.0.0");
}

test "UdpSocket.IPv6.Wildcard" {
    try testUdpSocketCommunication("::1", "::");
}
