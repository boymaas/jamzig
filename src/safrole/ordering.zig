const std = @import("std");

const trace = @import("tracing").scoped(.safrole);
const tracy = @import("tracy");

// (69) Outside in ordering function
pub fn outsideInOrdering(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]T {
    const span = trace.span(@src(), .z_outside_in_ordering);
    defer span.deinit();

    span.debug("Performing outside-in ordering on type {s}", .{@typeName(T)});
    span.trace("Input data length: {d}", .{data.len});

    const len = data.len;
    const result = try allocator.alloc(T, len);

    if (len == 0) {
        span.debug("Empty input data, returning empty result", .{});
        return result;
    }

    var left: usize = 0;
    var right: usize = len - 1;
    var index: usize = 0;

    while (left <= right) : (index += 1) {
        if (index % 2 == 0) {
            result[index] = data[left];
            left += 1;
        } else {
            result[index] = data[right];
            right -= 1;
        }
    }

    return result;
}

test outsideInOrdering {
    const testing = std.testing;
    const allocator = testing.allocator;

    {
        const input = [_]u32{ 1, 2, 3, 4, 5, 6 };
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{ 1, 6, 2, 5, 3, 4 }, result);
    }

    {
        const input = [_]u32{ 1, 2, 3, 4, 5 };
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{ 1, 5, 2, 4, 3 }, result);
    }

    {
        const input = [_]u32{1};
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{1}, result);
    }

    {
        const input = [_]u32{};
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{}, result);
    }
}
