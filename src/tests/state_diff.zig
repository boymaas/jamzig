const std = @import("std");
const types = @import("../types.zig");

const jam_params = @import("../jam_params.zig");

const state = @import("../state.zig");
const diff = @import("diff.zig");

pub fn JamStateDiff(
    params: jam_params.Params,
) type {
    return struct {
        fields: std.StringHashMap(diff.DiffResult),

        pub fn init(allocator: std.mem.Allocator) JamStateDiff(params) {
            return .{ .fields = std.StringHashMap(diff.DiffResult).init(allocator) };
        }

        pub fn hasChanges(self: *const @This()) bool {
            var it = self.fields.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.hasChanges()) {
                    return true;
                }
            }
            return false;
        }

        pub fn format(
            self: *const @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt; // Ignore the format string
            _ = options; // Ignore format options

            // Count the number of fields with diffs
            var diff_count: usize = 0;
            var it = self.fields.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.hasChanges()) {
                    diff_count += 1;
                }
            }

            if (diff_count == 0) {
                return;
            }

            try writer.print("\x1b[1;36mDifferences found in {d} field(s)\x1b[0m\n\n", .{diff_count});

            // Iterate through all fields and show diffs
            it = self.fields.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.hasChanges()) {
                    try writer.print("\x1b[1;33mField: {s}\x1b[0m\n", .{entry.key_ptr.*});
                    try writer.writeAll("\x1b[36m------------------------\x1b[0m\n");

                    switch (entry.value_ptr.*) {
                        .Diff => |output| try writer.writeAll(output),
                        .EmptyDiff => try writer.writeAll("<no differences>\n"),
                    }
                    try writer.writeAll("\n");
                }
            }
        }

        pub fn printToStdErr(self: *const @This()) void {
            std.debug.print("{}\n", .{self});
        }

        pub fn build(
            allocator: std.mem.Allocator,
            before: *const state.JamState(params),
            after: *const state.JamState(params),
        ) !JamStateDiff(params) {
            var state_diff = @This().init(allocator);
            var fields = &state_diff.fields;
            inline for (std.meta.fields(state.JamState(params))) |field| {
                try fields.put(field.name, try diff.diffBasedOnFormat(
                    allocator,
                    types.fmt.formatWithOptions(
                        @field(before, field.name),
                        .{ .ignore_fields = &[_][]const u8{"global_index"} },
                    ),
                    types.fmt.formatWithOptions(
                        @field(after, field.name),
                        .{ .ignore_fields = &[_][]const u8{"global_index"} },
                    ),
                ));
            }

            return state_diff;
        }

        pub fn deinit(self: *@This()) void {
            var it = self.fields.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(self.fields.allocator);
            }
            self.fields.deinit();
        }
    };
}
