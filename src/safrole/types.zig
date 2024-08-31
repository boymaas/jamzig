const std = @import("std");

pub const BlsKey = [144]u8;
pub const Ed25519Key = [32]u8;
pub const BandersnatchKey = [32]u8;
pub const OpaqueHash = [32]u8;

pub const TicketOrKey = union(enum) { tickets: []TicketBody, keys: []BandersnatchKey };

pub const EpochMark = struct {
    entropy: OpaqueHash,
    validators: []BandersnatchKey,
};

pub const TicketMark = []TicketBody;

pub const TicketBody = struct {
    id: OpaqueHash,
    attempt: u8,
};

pub const TicketEnvelope = struct {
    attempt: u8,
    signature: [784]u8,
};

pub const ValidatorData = struct {
    bandersnatch: BandersnatchKey,
    ed25519: Ed25519Key,
    bls: BlsKey,
    metadata: [128]u8,
};

// TODO: Make a custom type to handle TicketOrKey
// see mark-5
pub const GammaS = TicketOrKey;

pub const GammaZ = [144]u8; // types.hex.HexBytesFixed(144);

/// Represents a Safrole state of the system as referenced in the GP γ.
pub const State = struct {
    /// τ: The most recent block's timeslot, crucial for maintaining the temporal
    /// context in block production.
    tau: u32,

    /// η: The entropy accumulator, which contributes to the system's randomness
    /// and is updated with each block.
    eta: [4]OpaqueHash,

    /// λ: Validator keys and metadata from the previous epoch, essential for
    /// ensuring continuity and validating current operations.
    lambda: []ValidatorData,

    /// κ: Validator keys and metadata that are currently active, representing the
    /// validators responsible for the current epoch.
    kappa: []ValidatorData,

    /// γₖ: The keys for the validators of the next epoch, which help in planning
    /// the upcoming validation process.
    gamma_k: []ValidatorData,

    /// ι: Validator keys and metadata to be drawn from next, which indicates the
    /// future state and validators likely to be active.
    iota: []ValidatorData,

    /// γₐ: The sealing lottery ticket accumulator, part of the process ensuring
    /// randomness and fairness in block sealing.
    gamma_a: []TicketBody,

    /// γₛ: The sealing-key sequence for the current epoch, representing the order
    /// and structure of keys used in the sealing process.
    gamma_s: GammaS,

    /// γ𝑧: The Bandersnatch root for the current epoch’s ticket submissions,
    /// which is a cryptographic commitment to the current state of ticket
    /// submissions.
    gamma_z: GammaZ,
};

pub const Input = struct {
    slot: u32,
    entropy: OpaqueHash,
    extrinsic: []TicketEnvelope,
};

pub const Output = union(enum) {
    err: OutputError,
    ok: OutputMarks,
};

pub const OutputError = enum(u8) {
    /// Bad slot value.
    bad_slot = 0,
    /// Received a ticket while in epoch's tail.
    unexpected_ticket = 1,
    /// Tickets must be sorted.
    bad_ticket_order = 2,
    /// Invalid ticket ring proof.
    bad_ticket_proof = 3,
    /// Invalid ticket attempt value.
    bad_ticket_attempt = 4,
    /// Reserved
    reserved = 5,
    /// Found a ticket duplicate.
    duplicate_ticket = 6,
};

pub const OutputMarks = struct {
    epoch_mark: ?EpochMark,
    tickets_mark: ?TicketMark,
};
