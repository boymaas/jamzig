const std = @import("std");
const ssl = @import("ssl");
const lsquic = @import("lsquic");

const trace = @import("../../tracing.zig").scoped(.network);

// -- LSQUIC Logging

pub fn enableDetailedLsquicLogging() void {
    const logger_if = lsquic.lsquic_logger_if{
        .log_buf = lsquic_log_callback,
    };
    lsquic.lsquic_logger_init(&logger_if, null, lsquic.LLTS_HHMMSSMS);
}

fn lsquic_log_callback(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.C) c_int {
    _ = ctx; // unused
    const stderr = std.io.getStdErr().writer();
    stderr.print("\x1b[33mlsquic: \x1b[0m", .{}) catch return 0;
    stderr.writeAll(buf[0..len]) catch return 0;
    return 0;
}

// -- SSL Logging
pub fn enableDetailedSslCtxLogging(ssl_ctx: *ssl.SSL_CTX) void {
    const res = lsquic.lsquic_set_log_level("info");
    if (res != 0) {
        @panic("could not set lsquic log level");
    }

    ssl.SSL_CTX_set_info_callback(ssl_ctx, ssl_info_callback); // Register the callback
}

fn ssl_info_callback(ssl_handle: ?*const ssl.SSL, where_val: c_int, ret: c_int) callconv(.C) void {
    const span = trace.span(.ssl_info_callback);
    defer span.deinit();

    // Get state string only if handle is not null (can be null in early stages)
    const state_str = if (ssl_handle) |handle| ssl.SSL_state_string_long(handle) else @as([*c]const u8, @ptrCast("(null handle)"));
    span.debug("SSL state change", .{});
    span.trace("State='{s}', Where=0x{x}, Ret={d}", .{ state_str, where_val, ret });

    // Also output to standard debug log for visibility during development
    std.debug.print("\x1b[32mSSL INFO: State='{s}', Where=0x{x} ({s}), Ret={d}\x1b[0m\n", .{
        state_str,
        where_val,
        ssl.SSL_state_string_long(ssl_handle), // You might want more specific where flags decoded here
        ret,
    });

    // Add more detailed logging for alerts
    if ((where_val & ssl.SSL_CB_ALERT) != 0) {
        const is_write = (where_val & ssl.SSL_CB_WRITE) != 0;
        const alert_level_str = ssl.SSL_alert_type_string_long(ret); // Level is in upper byte of ret
        const alert_desc_str = ssl.SSL_alert_desc_string_long(ret); // Desc is in lower byte of ret

        span.debug("SSL alert {s}", .{if (is_write) "sent" else "received"});
        span.trace("Alert level: {s}, description: {s}, ret={d}", .{
            alert_level_str,
            alert_desc_str,
            ret,
        });

        std.debug.print("\x1b[31mSSL ALERT {s}: Level='{s}', Desc='{s}' (ret={d})\x1b[0m\n", .{
            if (is_write) "WRITE" else "READ",
            alert_level_str,
            alert_desc_str,
            ret,
        });
    }
}
