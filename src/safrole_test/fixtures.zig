const std = @import("std");

const TestVector = @import("../tests/vectors/libs/safrole.zig").TestVector;

const tests = @import("../tests.zig");
const safrole = @import("../safrole.zig");

pub const Fixtures = struct {
    pre_state: safrole.types.State,
    post_state: safrole.types.State,
    input: safrole.types.Input,
    output: safrole.types.Output,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        self.pre_state.deinit(allocator);
        self.input.deinit(allocator);
        self.post_state.deinit(allocator);
        self.output.deinit(allocator);
    }
};

pub fn buildFixtures(allocator: std.mem.Allocator, name: []const u8) !Fixtures {
    const tv_parsed = try TestVector.build_from(allocator, name);
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
    };
}
