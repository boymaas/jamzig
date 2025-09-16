comptime {
    _ = @import("tests/messages_test.zig");
    _ = @import("tests/fuzzer_test.zig");
    _ = @import("tests/v1_protocol_test.zig");
    _ = @import("tests/v1_conformance_test.zig");
    // _ = @import("state_converter_test.zig"); // TODO: re-enable when file exists

    // Include new target implementations for compilation validation
    _ = @import("target_interface.zig");
    _ = @import("socket_target.zig");
    _ = @import("embedded_target.zig");
}
