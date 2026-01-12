const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const Scanner = @import("../codec/scanner.zig").Scanner;
const state_decoding = @import("../state_decoding.zig");
const DecodingError = state_decoding.DecodingError;
const DecodingContext = state_decoding.DecodingContext;

const Eta = types.Eta;

pub fn decode(
    allocator: std.mem.Allocator,
    context: *DecodingContext,
    reader: anytype,
) !Eta {
    _ = allocator;

    try context.push(.{ .component = "eta" });
    defer context.pop();

    var eta: Eta = undefined;

    const buffer = std.mem.sliceAsBytes(&eta);
    reader.readNoEof(buffer) catch |err| {
        return context.makeError(error.EndOfStream, "failed to read entropy array: {s}", .{@errorName(err)});
    };

    return eta;
}

test "decode eta" {
    const allocator = testing.allocator;

    var sample_data = [_]u8{
        1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,
        17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,
        33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,
        49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
        65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,
        81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  96,
        97,  98,  99,  100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112,
        113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128,
    };

    var context = DecodingContext.init(allocator);
    defer context.deinit();

    var fbs = std.io.fixedBufferStream(&sample_data);
    const decoded = try decode(allocator, &context, fbs.reader());

    const expected_first = [_]u8{1} ** 1 ++ [_]u8{2} ** 1 ++ [_]u8{3} ** 1 ++ [_]u8{4} ** 1 ++ [_]u8{5} ** 1 ++ [_]u8{6} ** 1 ++ [_]u8{7} ** 1 ++ [_]u8{8} ** 1 ++ [_]u8{9} ** 1 ++ [_]u8{10} ** 1 ++ [_]u8{11} ** 1 ++ [_]u8{12} ** 1 ++ [_]u8{13} ** 1 ++ [_]u8{14} ** 1 ++ [_]u8{15} ** 1 ++ [_]u8{16} ** 1 ++ [_]u8{17} ** 1 ++ [_]u8{18} ** 1 ++ [_]u8{19} ** 1 ++ [_]u8{20} ** 1 ++ [_]u8{21} ** 1 ++ [_]u8{22} ** 1 ++ [_]u8{23} ** 1 ++ [_]u8{24} ** 1 ++ [_]u8{25} ** 1 ++ [_]u8{26} ** 1 ++ [_]u8{27} ** 1 ++ [_]u8{28} ** 1 ++ [_]u8{29} ** 1 ++ [_]u8{30} ** 1 ++ [_]u8{31} ** 1 ++ [_]u8{32} ** 1;
    try testing.expectEqualSlices(u8, &expected_first, &decoded[0]);

    var context2 = DecodingContext.init(allocator);
    defer context2.deinit();

    var short_data = [_]u8{1} ** 127;
    var short_fbs = std.io.fixedBufferStream(&short_data);
    try testing.expectError(error.EndOfStream, decode(allocator, &context2, short_fbs.reader()));
}
