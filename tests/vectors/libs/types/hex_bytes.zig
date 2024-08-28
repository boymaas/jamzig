const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const Error = error{ PrefixMismatch, LengthMismatch, UnexpectedToken, AllocNextError } || std.mem.Allocator.Error || std.fmt.ParseIntError;

pub fn HexBytesFixed(comptime size: u16) type {
    return struct {
        bytes: []u8,
        size: u16,

        pub fn jsonParse(allocator: Allocator, scanner: *json.Scanner, _: json.ParseOptions) json.ParseError(@TypeOf(scanner.*))!HexBytesFixed(size) {
            const bytes = nextHexStringToBytes(allocator, scanner) catch return error.SyntaxError;
            if (bytes.len != size) {
                return error.LengthMismatch;
            }
            return HexBytesFixed(size){ .bytes = bytes, .size = size };
        }
    };
}

pub const HexBytes = struct {
    bytes: []u8,

    pub fn jsonParse(allocator: Allocator, scanner: *json.Scanner, _: json.ParseOptions) json.ParseError(@TypeOf(scanner.*))!HexBytes {
        const bytes = nextHexStringToBytes(allocator, scanner) catch return error.SyntaxError;
        return HexBytes{ .bytes = bytes };
    }
};

pub fn nextHexStringToBytes(allocator: Allocator, scanner: *json.Scanner) Error![]u8 {
    const token = scanner.nextAlloc(allocator, .alloc_always) catch return error.AllocNextError;
    std.debug.print("token: {}\n", .{token});
    switch (token) {
        .allocated_string => |string| {
            // ensure the string starts with "0x"
            if (string.len < 2 or string[0] != '0' or string[1] != 'x') {
                return error.PrefixMismatch;
            }
            const bytes = try hexStringToBytes(allocator, string[2..]);
            return bytes;
        },
        else => {
            return error.UnexpectedToken;
        },
    }
}

pub fn hexStringToBytes(allocator: Allocator, hex_str: []const u8) Error![]u8 {
    const len = hex_str.len;
    if (len % 2 != 0) return error.LengthMismatch; // Ensure even number of characters

    const byte_count = len / 2;
    var result = try allocator.alloc(u8, byte_count);

    var i: usize = 0;
    while (i < byte_count) : (i += 1) {
        const hex_pair = hex_str[i * 2 .. i * 2 + 2];
        result[i] = try std.fmt.parseInt(u8, hex_pair, 16);
    }

    return result;
}
