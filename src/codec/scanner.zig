const std = @import("std");

pub const Scanner = struct {
    buffer: []const u8,

    pub fn initCompleteInput(buffer: []const u8) Scanner {
        return Scanner{ .buffer = buffer };
    }
};
