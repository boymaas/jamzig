const std = @import("std");

const TestVector = @import("../tests/vectors/libs/safrole.zig").TestVector;

const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");

const diff = @import("../safrole_test/diffz.zig");

pub const Fixtures = struct {
    pre_state: safrole.types.State,
    post_state: safrole.types.State,
    input: safrole.types.Input,
    output: safrole.types.Output,

    allocator: std.mem.Allocator,

    pub fn diffStates(self: @This()) ![]const u8 {
        return try diff.diffStates(self.allocator, &self.pre_state, &self.post_state);
    }

    pub fn diffStatesAndPrint(self: @This()) !void {
        const diff_result = self.diffStates() catch |err| {
            std.debug.print("DiffStates err {any}\n", .{err});
            return err;
        };
        defer self.allocator.free(diff_result);
        try std.io.getStdErr().writer().print("{s}\n", .{diff_result});
    }

    pub fn diffAgainstPostState(
        self: @This(),
        state: *safrole.types.State,
    ) ![]const u8 {
        return try diff.diffStates(
            self.allocator,
            &self.post_state,
            state,
        );
    }

    pub fn diffAgainstPostStateAndPrint(
        self: @This(),
        state: *safrole.types.State,
    ) !void {
        const diff_result = self.diffAgainstPostState(state) catch |err| {
            std.debug.print("DiffAgainstPostState err {any}\n", .{err});
            return err;
        };
        defer self.allocator.free(diff_result);
        try std.io.getStdErr().writer().print("{s}\n", .{diff_result});
    }

    pub fn deinit(self: @This()) void {
        self.pre_state.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.post_state.deinit(self.allocator);
        self.output.deinit(self.allocator);
    }
};

const TEST_VECTOR_PREFIX = "src/tests/vectors/jam/safrole/";

pub fn buildFixtures(allocator: std.mem.Allocator, name: []const u8) !Fixtures {
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ TEST_VECTOR_PREFIX, name });
    defer allocator.free(full_path);

    const tv_parsed = try TestVector.build_from(allocator, full_path);
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    // Assume these are populated from your JSON parsing
    const pre_state = try tests.stateFromTestVector(allocator, &tv.pre_state);
    const input = try tests.inputFromTestVector(allocator, &tv.input);

    const post_state = try tests.stateFromTestVector(allocator, &tv.post_state);
    const output = try tests.outputFromTestVector(allocator, &tv.output);

    return .{
        .pre_state = pre_state,
        .input = input,
        .post_state = post_state,
        .output = output,
        .allocator = allocator,
    };
}
