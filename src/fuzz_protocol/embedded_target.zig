const std = @import("std");
const messages = @import("messages.zig");
const target = @import("target.zig");
const target_interface = @import("target_interface.zig");
const io = @import("../io.zig");

const trace = @import("tracing").scoped(.fuzz_protocol);

/// Embedded target that processes messages directly using TargetServer logic
/// This provides identical behavior to socket-based targets without network overhead
pub fn EmbeddedTarget(comptime IOExecutor: type, comptime params: @import("../jam_params.zig").Params) type {
    return struct {
        allocator: std.mem.Allocator,
        target_server: target.TargetServer(IOExecutor, params),
        pending_response: ?messages.Message = null,

        pub const Config = struct {
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, executor: *IOExecutor, config: Config) !Self {
            _ = config;

            const target_server = target.TargetServer(IOExecutor, params).init(
                executor,
                allocator,
                "",
                .exit_on_disconnect
            ) catch |err| {
                std.log.err("Failed to initialize target server: {s}", .{@errorName(err)});
                return err;
            };

            return Self{
                .allocator = allocator,
                .target_server = target_server,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.pending_response) |*response| {
                response.deinit(self.allocator);
            }

            self.target_server.deinit();
            self.* = undefined;
        }

        /// Send message to embedded target
        pub fn sendMessage(self: *Self, comptime _: @import("../jam_params.zig").Params, message: messages.Message) !void {
            const span = trace.span(@src(), .embedded_send_message);
            defer span.deinit();
            span.debug("Processing message: {s}", .{@tagName(message)});

            if (self.pending_response) |*response| {
                response.deinit(self.allocator);
                self.pending_response = null;
            }

            const response = try self.target_server.processMessage(message);

            self.pending_response = response;

            if (response) |resp| {
                span.debug("Generated response: {s}", .{@tagName(resp)});
            } else {
                span.debug("No response generated", .{});
            }
        }

        /// Read response from embedded target
        pub fn readMessage(self: *Self, comptime _: @import("../jam_params.zig").Params) !messages.Message {
            const span = trace.span(@src(), .embedded_read_message);
            defer span.deinit();

            if (self.pending_response) |response| {
                const result = response;
                self.pending_response = null;
                span.debug("Returning response: {s}", .{@tagName(result)});
                return result;
            } else {
                span.err("No pending response available", .{});
                return error.NoPendingResponse;
            }
        }
    };
}

pub fn createEmbeddedTarget(
    comptime IOExecutor: type,
    allocator: std.mem.Allocator,
    executor: *IOExecutor,
    config: EmbeddedTarget(IOExecutor, @import("../jam_params.zig").TINY_PARAMS).Config
) !EmbeddedTarget(IOExecutor, @import("../jam_params.zig").TINY_PARAMS) {
    return EmbeddedTarget(IOExecutor, @import("../jam_params.zig").TINY_PARAMS).init(allocator, executor, config);
}

comptime {
    target_interface.validateTargetInterface(EmbeddedTarget(io.SequentialExecutor, @import("../jam_params.zig").TINY_PARAMS));
}