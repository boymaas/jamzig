const std = @import("std");
const pretty = @import("pretty");

const TestVector = @import("../tests/vectors/libs/safrole.zig").TestVector;

const tests = @import("../tests.zig");

test "format Input" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/safrole/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    const input = try tests.inputFromTestVector(allocator, &tv.input);
    input.deinit(allocator);

    // try pretty.print(allocator, input, .{});

    // std.debug.print("\n{any}\n", .{input});
}

test "format State" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/safrole/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    const pre_state = try tests.stateFromTestVector(allocator, &tv.pre_state);
    defer pre_state.deinit(allocator);

    std.debug.print("\n{any}\n", .{pre_state});
}

test "format State pretty" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/safrole/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    const pre_state = try tests.stateFromTestVector(allocator, &tv.pre_state);
    defer pre_state.deinit(allocator);

    // _ = try pretty.print(allocator, pre_state, .{});
    // defer pretty_state.deinit(allocator);
}

test "format Output" {
    const allocator = std.testing.allocator;
    const tv_parsed = try TestVector.build_from(allocator, "src/tests/vectors/safrole/safrole/tiny/enact-epoch-change-with-no-tickets-1.json");
    defer tv_parsed.deinit();
    const tv = &tv_parsed.value;

    const output = try tests.outputFromTestVector(allocator, &tv.output);
    defer output.deinit(allocator);

    std.debug.print("\n{any}\n", .{output});
}
