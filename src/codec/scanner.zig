const std = @import("std");

pub const Scanner = struct {
    buffer: []const u8,
    cursor: usize,

    pub fn initCompleteInput(buffer: []const u8) Scanner {
        return Scanner{ .buffer = buffer, .cursor = 0 };
    }

    pub fn remainingBuffer(self: *const Scanner) []const u8 {
        return self.buffer[self.cursor..];
    }

    pub fn advanceCursor(self: *@This(), n: usize) !void {
        if (n > self.buffer.len - self.cursor) {
            return error.OutOfRange;
        }

        self.cursor += n;
    }

    pub fn readBytes(self: *@This(), comptime n: usize) ![]const u8 {
        if (n > self.buffer.len - self.cursor) {
            return error.OutOfRange;
        }

        const bytes = self.buffer[self.cursor .. self.cursor + n];
        self.cursor += n;
        return bytes;
    }

    pub fn readByte(self: *@This()) !u8 {
        if (self.cursor >= self.buffer.len) {
            return error.OutOfRange;
        }

        const byte = self.buffer[self.cursor];
        self.cursor += 1;
        return byte;
    }
};
