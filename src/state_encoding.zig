const std = @import("std");
const state = @import("state.zig");

const alpha = @import("state_encoding/alpha.zig");
const beta = @import("state_encoding/beta.zig");
const gamma = @import("state_encoding/gamma.zig");
const phi = @import("state_encoding/phi.zig");
const psi = @import("state_encoding/psi.zig");
const rho = @import("state_encoding/rho.zig");

pub const encodeAlpha = alpha.encode;
pub const encodeBeta = beta.encode;
pub const encodeGamma = gamma.encode;
pub const encodePhi = phi.encode;
pub const encodePsi = psi.encode;
pub const encodeRho = rho.encode;

comptime {
    _ = @import("state_encoding/alpha.zig");
    _ = @import("state_encoding/beta.zig");
    _ = @import("state_encoding/gamma.zig");
    _ = @import("state_encoding/phi.zig");
    _ = @import("state_encoding/psi.zig");
    _ = @import("state_encoding/rho.zig");
}
