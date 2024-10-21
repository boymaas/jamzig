const std = @import("std");
const state = @import("state.zig");
const alpha = @import("state_encoding/alpha.zig");
const beta = @import("state_encoding/beta.zig");
const gamma = @import("state_encoding/gamma.zig");
const delta = @import("state_encoding/delta.zig");

pub const encodeAlpha = alpha.encode;
pub const encodeBeta = beta.encode;
pub const encodeGamma = gamma.encode;
pub const encodeDelta = delta.encode;

comptime {
    _ = @import("state_encoding/alpha.zig");
}
