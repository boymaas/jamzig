const std = @import("std");
const state = @import("state.zig");

pub const alpha = @import("state_encoding/alpha.zig");
pub const beta = @import("state_encoding/beta.zig");
pub const chi = @import("state_encoding/chi.zig");
pub const delta = @import("state_encoding/delta.zig");
pub const eta = @import("state_encoding/eta.zig");
pub const gamma = @import("state_encoding/gamma.zig");
pub const phi = @import("state_encoding/phi.zig");
pub const pi = @import("state_encoding/pi.zig");
pub const psi = @import("state_encoding/psi.zig");
pub const rho = @import("state_encoding/rho.zig");
pub const tau = @import("state_encoding/tau.zig");
pub const theta = @import("state_encoding/theta.zig");
pub const xi = @import("state_encoding/xi.zig");

pub const iota = @import("state_encoding/validator_datas.zig");
pub const kappa = @import("state_encoding/validator_datas.zig");
pub const lambda = @import("state_encoding/validator_datas.zig");

pub const encodeAlpha = alpha.encode;
pub const encodeBeta = beta.encode;
pub const encodeChi = chi.encode;
pub const encodeEta = eta.encode;
pub const encodeGamma = gamma.encode;
pub const encodePhi = phi.encode;
pub const encodePi = pi.encode;
pub const encodePsi = psi.encode;
pub const encodeTau = tau.encode;
pub const encodeTheta = theta.encode;
pub const encodeRho = rho.encode;
pub const encodeIota = iota.encode;
pub const encodeKappa = kappa.encode;
pub const encodeLambda = lambda.encode;
pub const encodeXi = xi.encode;

comptime {
    _ = @import("state_encoding/alpha.zig");
    _ = @import("state_encoding/beta.zig");
    _ = @import("state_encoding/chi.zig");
    _ = @import("state_encoding/delta.zig");
    _ = @import("state_encoding/eta.zig");
    _ = @import("state_encoding/gamma.zig");
    _ = @import("state_encoding/phi.zig");
    _ = @import("state_encoding/pi.zig");
    _ = @import("state_encoding/psi.zig");
    _ = @import("state_encoding/rho.zig");
    _ = @import("state_encoding/tau.zig");
    _ = @import("state_encoding/theta.zig");
    _ = @import("state_encoding/validator_datas.zig");
    _ = @import("state_encoding/xi.zig");
}
