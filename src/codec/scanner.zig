const std = @import("std");
const errors = @import("errors.zig");

pub const Scanner = struct {
    buffer: []const u8,
    cursor: usize,

    pub fn init(buffer: []const u8) Scanner {
        return Scanner{ .buffer = buffer, .cursor = 0 };
    }

    pub fn remainingBuffer(self: *const Scanner) []const u8 {
        return self.buffer[self.cursor..];
    }

    pub fn advanceCursor(self: *Scanner, n: usize) !void {
        if (n > self.buffer.len - self.cursor) {
            return errors.ScannerError.BufferOverrun;
        }

        self.cursor += n;
    }

    pub fn readBytes(self: *Scanner, comptime n: usize) ![]const u8 {
        if (n > self.buffer.len - self.cursor) {
            return errors.ScannerError.BufferOverrun;
        }

        const bytes = self.buffer[self.cursor .. self.cursor + n];
        self.cursor += n;
        return bytes;
    }

    pub fn readByte(self: *Scanner) !u8 {
        if (self.cursor >= self.buffer.len) {
            return errors.ScannerError.BufferOverrun;
        }

        const byte = self.buffer[self.cursor];
        self.cursor += 1;
        return byte;
    }
};
