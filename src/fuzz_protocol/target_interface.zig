const std = @import("std");
const messages = @import("messages.zig");

pub fn TargetInterface(comptime Self: type) type {
    return struct {
        const Config = Self.Config;

        pub const init = Self.init;

        pub const sendMessage = Self.sendMessage;

        pub const readMessage = Self.readMessage;

        pub const deinit = Self.deinit;

        pub const connectToTarget = if (@hasDecl(Self, "connectToTarget")) Self.connectToTarget else null;

        pub const disconnect = if (@hasDecl(Self, "disconnect")) Self.disconnect else null;
    };
}

pub fn validateTargetInterface(comptime T: type) void {
    _ = T.Config;
    _ = T.init;
    _ = T.sendMessage;
    _ = T.readMessage;
    _ = T.deinit;
}

