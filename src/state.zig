const std = @import("std");
const types = @import("types.zig");
const safrole_types = @import("safrole/types.zig");

/// This struct represents the full state (`σ`) of the Jam protocol.
/// It contains segments for core consensus, validator management, service state, and protocol-level metadata.
/// Each component of the state represents a specific functional segment, allowing partitioned state management.
pub const JamState = struct {
    /// α: Core authorization state and associated queues.
    /// Manipulated in: src/authorization.zig
    alpha: Alpha,

    /// β: Metadata of the latest block, including block number, timestamps, and cryptographic references.
    /// Manipulated in: src/recent_blocks.zig
    beta: Beta,

    /// γ: List of current validators and their states, such as stakes and identities.
    /// Manipulated in: src/safrole.zig
    gamma: Gamma,

    /// δ: Service accounts state, managing all service-related data (similar to smart contracts).
    /// Manipulated in: src/services.zig
    delta: Delta,

    /// η: On-chain entropy pool used for randomization and consensus mechanisms.
    /// Manipulated in: src/safrole.zig
    eta: Eta,

    /// ι: Validators enqueued for activation in the upcoming epoch.
    /// Manipulated in: src/safrole.zig
    iota: Iota,

    /// κ: Active validator set currently responsible for validating blocks and maintaining the network.
    /// Manipulated in: src/safrole.zig
    kappa: Kappa,

    /// λ: Archived validators who have been removed or rotated out of the active set.
    /// Manipulated in: src/safrole.zig
    lambda: Lambda,

    /// ρ: State related to each core’s current assignment, including work packages and reports.
    /// Manipulated in: src/core_assignments.zig
    rho: Rho,

    /// τ: Current time, represented in terms of epochs and slots.
    /// Manipulated in: src/safrole.zig
    tau: Tau,

    /// φ: Authorization queue for tasks or processes awaiting authorization by the network.
    /// Manipulated in: src/authorization.zig
    phi: Phi,

    /// χ: Privileged service identities, which may have special roles within the protocol.
    /// Manipulated in: src/services.zig
    chi: Chi,

    /// ψ: Judgement state, tracking disputes or reports about validators or state transitions.
    /// Manipulated in: src/disputes.zig
    psi: Psi,

    /// π: Validator performance statistics, tracking penalties, rewards, and other metrics.
    /// Manipulated in: src/validator_stats.zig
    pi: Pi,
};

pub const Alpha = @import("authorization.zig").Alpha;
pub const Beta = @import("recent_blocks.zig").RecentHistory;
pub const Gamma = struct {
    k: safrole_types.GammaK,
    z: safrole_types.GammaZ,
    s: safrole_types.GammaS,
    a: safrole_types.GammaA,
};
pub const Delta = @import("services.zig").Delta;
pub const Eta = safrole_types.Eta;
pub const Iota = []safrole_types.ValidatorData;
pub const Kappa = safrole_types.Kappa;
pub const Lambda = safrole_types.Lambda;
pub const Rho = @import("pending_reports.zig").Rho;
pub const Tau = types.TimeSlot;
pub const Phi = @import("authorization_queue.zig").Phi;
pub const Chi = @import("services_priviledged.zig").Chi;
pub const Psi = @import("disputes.zig").Psi;
pub const Pi = struct {};
