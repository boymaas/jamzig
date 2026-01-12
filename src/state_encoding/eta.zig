const std = @import("std");
const testing = std.testing;

const Eta = @import("../types.zig").Eta;

const trace = @import("tracing").scoped(.codec);

pub fn encode(self: *const Eta, writer: anytype) !void {
    const span = trace.span(@src(), .encode_entropy_pool);
    defer span.deinit();

    span.debug("Starting Eta encoding", .{});
    span.trace("Eta buffer length: {d}", .{self.len});

    const first_pass_span = span.child(@src(), .first_pass);
    defer first_pass_span.deinit();

    first_pass_span.debug("Starting entropy encoding", .{});
    for (self, 0..) |entropy_item, i| {
        const item_span = first_pass_span.child(@src(), .entropy_item);
        defer item_span.deinit();

        item_span.debug("Processing entropy item {d}", .{i});
        item_span.trace("Entropy data: {any}", .{std.fmt.fmtSliceHexLower(&entropy_item)});

        try writer.writeAll(&entropy_item);
    }
}

test "encode" {
    const allocator = std.testing.allocator;
    var eta = Eta{
        .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 },
        .{ 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64 },
        .{ 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96 },
        .{ 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128 },
    };

    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();

    try encode(&eta, encoded.writer());

    try testing.expectEqualSlices(u8, &.{
        1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,
        17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,
        33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,
        49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
        65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,
        81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  96,
        97,  98,  99,  100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112,
        113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128,
    }, encoded.items);
}
