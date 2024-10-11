const std = @import("std");
const types = @import("types.zig");
const safrole_types = @import("safrole/types.zig");

// This struct represents the full state (`σ`) of the Jam protocol.
// It contains segments for core consensus, validator management, service state, and protocol-level metadata.
// Each component of the state represents a specific functional segment, allowing partitioned state management.

pub const JamState = struct {
    /// α: Core authorization state and associated queues.
    alpha: Alpha,

    /// β: Metadata of the latest block, including block number, timestamps, and cryptographic references.
    beta: Beta,

    /// γ: List of current validators and their states, such as stakes and identities.
    gamma: Gamma,

    /// δ: Service accounts state, managing all service-related data (similar to smart contracts).
    delta: Delta,

    /// η: On-chain entropy pool used for randomization and consensus mechanisms.
    eta: Eta,

    /// ι: Validators enqueued for activation in the upcoming epoch.
    iota: Iota,

    /// κ: Active validator set currently responsible for validating blocks and maintaining the network.
    kappa: Kappa,

    /// λ: Archived validators who have been removed or rotated out of the active set.
    lambda: Lambda,

    /// ρ: State related to each core’s current assignment, including work packages and reports.
    rho: Rho,

    /// τ: Current time, represented in terms of epochs and slots.
    tau: Tau,

    /// φ: Authorization queue for tasks or processes awaiting authorization by the network.
    phi: Phi,

    /// χ: Privileged service identities, which may have special roles within the protocol.
    chi: Chi,

    /// ψ: Judgement state, tracking disputes or reports about validators or state transitions.
    psi: Psi,

    /// π: Validator performance statistics, tracking penalties, rewards, and other metrics.
    pi: Pi,
};

// Structs for each state component, using types from safrole/types.zig where applicable
const Alpha = struct {};
const Beta = struct {};
const Gamma = struct {
    k: safrole_types.GammaK,
    z: safrole_types.GammaZ,
    s: safrole_types.GammaS,
    a: safrole_types.GammaA,
};
const Delta = struct {};
const Eta = safrole_types.Eta;
const Iota = []safrole_types.ValidatorData;
const Kappa = safrole_types.Kappa;
const Lambda = safrole_types.Lambda;
const Rho = struct {};
const Tau = types.TimeSlot;
const Phi = struct {};
const Chi = struct {};
const Psi = struct {};
const Pi = struct {};
