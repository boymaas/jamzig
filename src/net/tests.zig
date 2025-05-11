comptime {
    _ = @import("tests/server_test.zig");
    _ = @import("tests/client_test.zig");
    _ = @import("tests/simple_connect_test.zig");
    _ = @import("tests/create_stream_and_send_receive_data.zig");

    // -- JAMSNPSERVER TESTS
    _ = @import("tests/jamsnp_simple_connect_test.zig");
}
