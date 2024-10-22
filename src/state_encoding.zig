const std = @import("std");
const state = @import("state.zig");

const alpha = @import("state_encoding/alpha.zig");
const beta = @import("state_encoding/beta.zig");
const chi = @import("state_encoding/chi.zig");
const eta = @import("state_encoding/eta.zig");
const gamma = @import("state_encoding/gamma.zig");
const phi = @import("state_encoding/phi.zig");
const pi = @import("state_encoding/pi.zig");
const psi = @import("state_encoding/psi.zig");
const rho = @import("state_encoding/rho.zig");
const tau = @import("state_encoding/tau.zig");
const theta = @import("state_encoding/theta.zig");
const xi = @import("state_encoding/xi.zig");

const iota = @import("state_encoding/validator_datas.zig");
const kappa = @import("state_encoding/validator_datas.zig");
const lambda = @import("state_encoding/validator_datas.zig");

pub const encodeAlpha = alpha.encode;
pub const encodeBeta = beta.encode;
pub const encodeChi = chi.encode;
pub const encodeEta = eta.encode;
pub const encodeGamma = gamma.encode;
pub const encodePhi = phi.encode;
pub const encodePi = phi.encode;
pub const encodePsi = psi.encode;
pub const encodeTau = rho.encode;
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
