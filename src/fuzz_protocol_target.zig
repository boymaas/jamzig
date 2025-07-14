const std = @import("std");
const target = @import("fuzz_protocol/target.zig");
const TargetServer = target.TargetServer;
const RestartBehavior = target.RestartBehavior;

const trace = @import("tracing.zig").scoped(.fuzz_target_main);

const Config = struct {
    socket_path: []const u8 = "/tmp/jam_target.sock",
    help: bool = false,
};

fn printUsage() void {
    std.debug.print(
        \\Usage: fuzz_protocol_target [options]
        \\
        \\Options:
        \\  --socket PATH    Unix domain socket path (default: /tmp/jam_target.sock)
        \\  --help          Show this help message
        \\
        \\This program implements a JAM protocol conformance testing target server.
        \\It listens on a Unix domain socket for incoming fuzzer connections and
        \\processes protocol messages according to the FUZZ_PROTOCOL specification.
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var config = Config{};
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "--help")) {
            config.help = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --socket requires a path argument\n", .{});
                return error.InvalidArgument;
            }
            config.socket_path = args[i];
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
            return error.InvalidArgument;
        }
    }
    
    return config;
}

pub fn main() !void {
    const span = trace.span(.main);
    defer span.deinit();
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = parseArgs(allocator) catch {
        printUsage();
        return;
    };
    
    if (config.help) {
        printUsage();
        return;
    }
    
    span.debug("Starting JAM protocol conformance testing target server", .{});
    span.debug("Socket path: {s}", .{config.socket_path});
    
    var server = try TargetServer.init(allocator, config.socket_path, .exit_on_disconnect);
    defer server.deinit();
    
    // Setup signal handler for graceful shutdown
    var sigaction = std.posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handler(_: c_int) callconv(.C) void {
                std.debug.print("\nReceived signal, shutting down...\n", .{});
                std.process.exit(0);
            }
        }.handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    
    std.posix.sigaction(std.posix.SIG.INT, &sigaction, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);
    
    std.debug.print("JAM Protocol Target Server starting...\n", .{});
    std.debug.print("Listening on Unix socket: {s}\n", .{config.socket_path});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});
    
    // Start the server (this will block until interrupted)
    try server.start();
}