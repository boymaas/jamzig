const std = @import("std");
const state = @import("state.zig");

pub const alpha = @import("state_decoding/alpha.zig");
pub const beta = @import("state_decoding/beta.zig");
pub const chi = @import("state_decoding/chi.zig");
pub const delta = @import("state_decoding/delta.zig");
pub const eta = @import("state_decoding/eta.zig");
pub const gamma = @import("state_decoding/gamma.zig");
pub const phi = @import("state_decoding/phi.zig");
pub const pi = @import("state_decoding/pi.zig");
pub const psi = @import("state_decoding/psi.zig");
pub const rho = @import("state_decoding/rho.zig");
pub const tau = @import("state_decoding/tau.zig");
pub const theta = @import("state_decoding/theta.zig");
pub const xi = @import("state_decoding/xi.zig");

pub const iota = @import("state_decoding/validator_datas.zig");
pub const kappa = @import("state_decoding/validator_datas.zig");
pub const lambda = @import("state_decoding/validator_datas.zig");

pub const decodeAlpha = alpha.decode;
pub const decodeBeta = beta.decode;
pub const decodeChi = chi.decode;
pub const decodeEta = eta.decode;
pub const decodeGamma = gamma.decode;
pub const decodePhi = phi.decode;
pub const decodePi = pi.decode;
pub const decodePsi = psi.decode;
pub const decodeTau = tau.decode;
pub const decodeTheta = theta.decode;
pub const decodeRho = rho.decode;
pub const decodeIota = iota.decode;
pub const decodeKappa = kappa.decode;
pub const decodeLambda = lambda.decode;
pub const decodeXi = xi.decode;

comptime {
    _ = @import("state_decoding/alpha.zig");
    _ = @import("state_decoding/beta.zig");
    _ = @import("state_decoding/chi.zig");
    _ = @import("state_decoding/delta.zig");
    _ = @import("state_decoding/eta.zig");
    _ = @import("state_decoding/gamma.zig");
    _ = @import("state_decoding/phi.zig");
    _ = @import("state_decoding/pi.zig");
    _ = @import("state_decoding/psi.zig");
    _ = @import("state_decoding/rho.zig");
    _ = @import("state_decoding/tau.zig");
    _ = @import("state_decoding/theta.zig");
    _ = @import("state_decoding/validator_datas.zig");
    _ = @import("state_decoding/xi.zig");
}

pub const DecodingError = error{
    InvalidData,
    OutOfMemory,
    EndOfStream,
    InvalidSize,
    InvalidFormat,
    InvalidValue,
    InvalidState,
};
