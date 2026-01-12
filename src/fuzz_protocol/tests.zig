comptime {
    _ = @import("tests/messages_test.zig");
    _ = @import("tests/fuzzer_test.zig");

    _ = @import("target_interface.zig");
    _ = @import("socket_target.zig");
    _ = @import("embedded_target.zig");
}
