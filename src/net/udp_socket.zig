const std = @import("std");
const posix = std.posix;

// Based of off: https://cookbook.ziglang.cc/04-03-udp-echo.html
pub const UdpSocket = struct {
    socket: posix.socket_t,
    bound_address: ?std.net.Address = null,

    const Datagram = struct {
        bytes_read: []const u8,
        source: std.net.Address,
    };

    pub fn init() !UdpSocket {
        const socket = try posix.socket(posix.AF.INET6, posix.SOCK.DGRAM, 0);

        return UdpSocket{ .socket = socket };
    }

    pub fn deinit(self: *UdpSocket) void {
        posix.close(self.socket);
    }

    /// Bind the socket to address:port
    pub fn bind(self: *UdpSocket, addr: []const u8, port: u16) !void {
        const address = try std.net.Address.parseIp(addr, port);

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

        // Convert from POSIX sockaddr.in6 to Zig's Address type
        // TODO: Check if this is actually an IPv4-mapped IPv6 address

        return .{
            .bytes_read = buffer[0..bytes_read],
            .source = std.net.Address.initPosix(&src_addr),
        };
    }

    /// Send data to a specific address
    pub fn sendTo(self: *UdpSocket, data: []const u8, addr: std.net.Address) !usize {
        // Convert the Zig Address to the OS-specific sockaddr representation

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
};

const testing = std.testing;

// Simple test that sends "JamZig" over UDP
test UdpSocket {
    // Create receiver socket on a system
    // assiged port
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
}
