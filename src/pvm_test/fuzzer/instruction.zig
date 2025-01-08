const std = @import("std");

pub fn encoder(writer: anytype) Encoder(@TypeOf(writer)) {
    return .{ .writer = writer };
}

pub fn Encoder(comptime T: type) type {
    return struct {
        writer: T,

        pub fn encodeNoArgs(self: *@This(), opcode: u8) !u8 {
            try self.writer.writeByte(opcode);
            return 1;
        }

        pub fn encodeOneImm(self: *@This(), opcode: u8, imm: u32) !u8 {
            const l_x = calcLengthNeeded(imm);
            try self.writer.writeByte(opcode);
            try self.writeImm(imm, l_x);
            return l_x;
        }

        pub fn encodeTwoImm(self: *@This(), opcode: u8, imm1: u32, imm2: u32) !u8 {
            const l_x = calcLengthNeeded(imm1);
            const l_y = calcLengthNeeded(imm2);
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(l_x << 4);
            try self.writeImm(imm1, l_x);
            try self.writeImm(imm2, l_y);
            return l_x + l_y + 1;
        }

        pub fn encodeOneOffset(self: *@This(), opcode: u8, offset: i32) !u8 {
            const l_x = calcLengthNeeded(@bitCast(offset));
            try self.writer.writeByte(opcode);
            try self.writeImm(@as(u32, @bitCast(offset)), l_x);
            return l_x + 1;
        }

        pub fn encodeOneRegOneExtImm(self: *@This(), opcode: u8, reg_a: u8, imm: u32) !u8 {
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a);
            try self.writer.writeInt(u32, imm, .little);
            return 2 + 8;
        }

        pub fn encodeOneRegOneImm(self: *@This(), opcode: u8, reg_a: u8, imm: u32) !u8 {
            const l_x = calcLengthNeeded(imm);
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a);
            try self.writeImm(imm, l_x);
            return l_x + 1;
        }

        pub fn encodeOneRegTwoImm(self: *@This(), opcode: u8, reg_a: u8, imm1: u32, imm2: u32) !u8 {
            const l_x = calcLengthNeeded(imm1);
            const l_y = calcLengthNeeded(imm2);
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (l_x << 4));
            try self.writeImm(imm1, l_x);
            try self.writeImm(imm2, l_y);
            return l_x + l_y + 2;
        }

        pub fn encodeOneRegOneImmOneOffset(self: *@This(), opcode: u8, reg_a: u8, imm: u32, offset: i32) !u8 {
            const l_x = calcLengthNeeded(imm);
            const l_y = calcLengthNeeded(@as(u32, @bitCast(offset)));
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (l_x << 4));
            try self.writeImm(imm, l_x);
            try self.writeImm(@as(u32, @bitCast(offset)), l_y);
            return l_x + l_y + 2;
        }

        pub fn encodeTwoReg(self: *@This(), opcode: u8, reg_a: u8, reg_b: u8) !u8 {
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (reg_b << 4));
            return 1;
        }

        pub fn encodeTwoRegOneImm(self: *@This(), opcode: u8, reg_a: u8, reg_b: u8, imm: u32) !u8 {
            const l_x = calcLengthNeeded(imm);
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (reg_b << 4));
            try self.writeImm(imm, l_x);
            return l_x + 2;
        }

        pub fn encodeTwoRegOneOffset(self: *@This(), opcode: u8, reg_a: u8, reg_b: u8, offset: i32) !u8 {
            const l_x = calcLengthNeeded(@bitCast(offset));
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (reg_b << 4));
            try self.writeImm(@bitCast(offset), l_x);
            return l_x + 2;
        }

        pub fn encodeTwoRegTwoImm(self: *@This(), opcode: u8, reg_a: u8, reg_b: u8, imm1: u32, imm2: u32) !u8 {
            const l_x = calcLengthNeeded(imm1);
            const l_y = calcLengthNeeded(imm2);
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (reg_b << 4));
            try self.writer.writeByte(l_x);
            try self.writeImm(imm1, l_x);
            try self.writeImm(imm2, l_y);
            return l_x + l_y + 3;
        }

        pub fn encodeThreeReg(self: *@This(), opcode: u8, reg_a: u8, reg_b: u8, reg_d: u8) !u8 {
            try self.writer.writeByte(opcode);
            try self.writer.writeByte(reg_a | (reg_b << 4));
            try self.writer.writeByte(reg_d);
            return 3;
        }

        pub fn encodeJump(self: *@This(), target: u32) !u8 {
            const l_x = calcLengthNeeded(target);
            try self.writer.writeByte(40);
            try self.writeImm(target, l_x);
            return l_x;
        }

        fn calcLengthNeeded(value: u32) u8 {
            var buffer: [MAX_SIZE_IN_BYTES]u8 = undefined;
            const signed: i32 = @bitCast(value);
            std.mem.writeInt(i32, &buffer, @intCast(signed), .little);

            var len: u8 = MAX_SIZE_IN_BYTES;
            const sign_byte = if (signed < 0) @as(u8, 0xff) else 0;
            while (len > 0 and buffer[len - 1] == sign_byte) : (len -= 1) {}

            return len;
        }

        fn writeImm(self: *@This(), value: u32, len: u8) !void {
            var buffer: [MAX_SIZE_IN_BYTES]u8 = undefined;
            const signed: i32 = @bitCast(value);
            std.mem.writeInt(i32, &buffer, signed, .little);

            if (len > 0) {
                for (buffer[0..len]) |byte| {
                    try self.writer.writeByte(byte);
                }
            } else {
                try self.writer.writeByte(0);
            }
        }

        const MAX_SIZE_IN_BYTES: usize = 4;
    };
}
