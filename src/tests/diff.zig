const std = @import("std");

const tmpfile = @import("tmpfile");

const tfmt = @import("../types/fmt.zig");

pub const DiffResult = union(enum) {
    EmptyDiff,
    Diff: []u8,

    pub fn debugPrint(self: @This()) void {
        switch (self) {
            .EmptyDiff => {
                // std.debug.print("<empty diff>\n", .{});
            },
            .Diff => |diff| {
                std.debug.print("\n\n", .{});
                std.debug.print("\x1b[38;5;208m+ = in expected, not in actual => add to actual\x1b[0m\n", .{});
                std.debug.print("\x1b[38;5;208m- = in actual, not in expected => remove from actual\x1b[0m\n", .{});
                std.debug.print("{s}", .{diff});
            },
        }
    }

    pub fn debugPrintAndDeinit(self: @This(), allocator: std.mem.Allocator) void {
        defer self.deinit(allocator);
        self.debugPrint();
    }

    pub fn debugPrintAndReturnErrorOnDiff(self: *const @This()) !void {
        self.debugPrint();

        switch (self.*) {
            .Diff => {
                return error.DiffMismatch;
            },
            else => {},
        }
    }

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Diff => allocator.free(self.Diff),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn diffBasedOnTypesFormat(
    allocator: std.mem.Allocator,
    actual: anytype,
    expected: anytype,
) !DiffResult {

    // Print both before and after states
    const actual_str = try tfmt.formatAlloc(allocator, actual);
    defer allocator.free(actual_str);
    const expected_str = try tfmt.formatAlloc(allocator, expected);
    defer allocator.free(expected_str);

    return diffBasedOnStrings(allocator, actual_str, expected_str);
}

pub fn diffBasedOnFormat(
    allocator: std.mem.Allocator,
    before: anytype,
    after: anytype,
) !DiffResult {

    // Print both before and after states
    const before_str = try std.fmt.allocPrint(allocator, "{any}", .{before});
    defer allocator.free(before_str);
    const after_str = try std.fmt.allocPrint(allocator, "{any}", .{after});
    defer allocator.free(after_str);

    return diffBasedOnStrings(allocator, before_str, after_str);
}

pub fn diffBasedOnStrings(allocator: std.mem.Allocator, before_str: []const u8, after_str: []const u8) !DiffResult {
    if (std.mem.eql(u8, before_str, after_str)) {
        return .EmptyDiff;
    }

    // Create temporary files to store the before and after states
    var before_file = try tmpfile.tmpFile(.{});
    defer before_file.deinit();
    var after_file = try tmpfile.tmpFile(.{});
    defer after_file.deinit();

    // Write to the tempfiles
    try before_file.f.writeAll(before_str);
    try after_file.f.writeAll(after_str);

    // Now do a context diff between the two files
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "diff",
            "-u",
            before_file.abs_path,
            after_file.abs_path,
        },
    });
    defer allocator.free(result.stderr);

    // Return the owned slice, to be freed by caller
    return .{ .Diff = result.stdout };
}

pub fn printDiffBasedOnFormatToStdErr(
    allocator: std.mem.Allocator,
    before: anytype,
    after: anytype,
) !void {
    var diff = try diffBasedOnFormat(allocator, before, after);
    defer diff.deinit(allocator);

    diff.debugPrint();
}

/// Test function to compare two values based on their evaluated format
/// Returns an error after printing the diff
pub fn expectFormattedEqual(
    comptime T: type,
    allocator: std.mem.Allocator,
    actual: T,
    expected: T,
) !void {
    var diff = try diffBasedOnFormat(allocator, actual, expected);
    defer diff.deinit(allocator);
    try diff.debugPrintAndReturnErrorOnDiff();
}

// Compare values using types/fmt formatting without requiring custom formatters
pub fn expectTypesFmtEqual(
    comptime T: type,
    allocator: std.mem.Allocator,
    actual: T,
    expected: T,
) !void {
    const actual_str = try tfmt.formatAlloc(allocator, actual);
    defer allocator.free(actual_str);
    const expected_str = try tfmt.formatAlloc(allocator, expected);
    defer allocator.free(expected_str);

    var diff = try diffBasedOnStrings(allocator, actual_str, expected_str);
    defer diff.deinit(allocator);
    try diff.debugPrintAndReturnErrorOnDiff();
}
