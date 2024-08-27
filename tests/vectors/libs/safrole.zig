const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const HexBytes = struct {
    bytes: []u8,

    pub fn jsonParse(allocator: Allocator, scanner: *json.Scanner, _: json.ParseOptions) json.ParseError(@TypeOf(scanner.*))!HexBytes {
        const token = try scanner.nextAlloc(allocator, .alloc_always);
        std.debug.print("token: {}\n", .{token});
        switch (token) {
            .allocated_string => |string| {
                // ensure the string starts with "0x"
                if (string.len < 2 or string[0] != '0' or string[1] != 'x') {
                    return error.UnexpectedToken;
                }
                const bytes = try HexBytes.hexStringToBytes(allocator, string[2..]);
                return HexBytes{ .bytes = bytes };
            },
            else => {
                return error.UnexpectedToken;
            },
        }
    }

    pub fn hexStringToBytes(allocator: Allocator, hex_str: []const u8) json.ParseError(json.Scanner)![]u8 {
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
};

const Input = struct {
    slot: u64,
    entropy: HexBytes,
    extrinsic: []Extrinsic,
};

const Extrinsic = struct {
    attempt: u8,
    signature: HexBytes,
};

const KeySet = struct {
    bandersnatch: HexBytes,
    ed25519: HexBytes,
    bls: HexBytes,
    metadata: HexBytes,
};

const GammaS = struct {
    keys: []HexBytes,
};

const State = struct {
    tau: u64,
    eta: []HexBytes,
    lambda: []KeySet,
    kappa: []KeySet,
    gamma_k: []KeySet,
    iota: []KeySet,
    gamma_a: []KeySet,
    gamma_s: GammaS,
    gamma_z: HexBytes,
};

const Output = struct {
    err: ?[]u8,
};

pub const TestVector = struct {
    input: Input,
    pre_state: State,
    output: Output,
    post_state: State,

    pub fn build_from(allocator: Allocator, file_path: []const u8) !json.Parsed(TestVector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }

        return try json.parseFromSlice(TestVector, allocator, buffer, .{ .ignore_unknown_fields = true, .parse_numbers = false });
    }
};
