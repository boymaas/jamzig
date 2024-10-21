const std = @import("std");
const state = @import("state.zig");
const alpha = @import("state_encoding/alpha.zig");
const beta = @import("state_encoding/beta.zig");
const rho = @import("state_encoding/rho.zig");

pub const encodeAlpha = alpha.encode;
pub const encodeBeta = beta.encode;
pub const encodeRho = rho.encode;

comptime {
    _ = @import("state_encoding/alpha.zig");
    _ = @import("state_encoding/beta.zig");
    _ = @import("state_encoding/rho.zig");
}
