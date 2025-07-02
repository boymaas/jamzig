comptime {
    _ = @import("tests/messages_test.zig");
    _ = @import("tests/target_manager_test.zig");
    _ = @import("tests/threadless/threadless.zig");
    _ = @import("tests/fuzzer_test.zig");
    // _ = @import("state_converter_test.zig"); // TODO: re-enable when file exists
}
