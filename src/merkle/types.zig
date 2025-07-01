const types = @import("../types.zig");

pub const Key = types.StateKey; // 31 bytes per JAM 0.6.6
pub const Hash = [32]u8;

pub const Blob = []const u8;
pub const Blobs = []const []const u8;
