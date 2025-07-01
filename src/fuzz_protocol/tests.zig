comptime {
    _ = @import("tests/target_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("tests/sequoia_test.zig");
    // _ = @import("state_converter_test.zig"); // TODO: re-enable when file exists
}

