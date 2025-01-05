const std = @import("std");

const trace = @import("../tracing.zig").scoped(.safrole);

// (69) Outside in ordering function
pub fn outsideInOrdering(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]T {
    const span = trace.span(.z_outside_in_ordering);
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

    // Test case 1: Even number of elements
    {
        const input = [_]u32{ 1, 2, 3, 4, 5, 6 };
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{ 1, 6, 2, 5, 3, 4 }, result);
    }

    // Test case 2: Odd number of elements
    {
        const input = [_]u32{ 1, 2, 3, 4, 5 };
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{ 1, 5, 2, 4, 3 }, result);
    }

    // Test case 3: Single element
    {
        const input = [_]u32{1};
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{1}, result);
    }

    // Test case 4: Empty input
    {
        const input = [_]u32{};
        const result = try outsideInOrdering(u32, allocator, &input);
        defer allocator.free(result);

        try testing.expectEqualSlices(u32, &[_]u32{}, result);
    }
}
