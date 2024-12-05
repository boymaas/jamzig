/// State Transition Function (Υ)
///
/// The state transition function Υ is the core of the Jam protocol, defining how
/// the blockchain state σ changes with each new block B:
///
///     σ' ≡ Υ(σ, B)
///
/// Dependencies and Execution Order:
/// 1. Time-related updates (τ')
/// 2. Recent history updates (β')
/// 3. Consensus mechanism updates (γ')
/// 4. Entropy accumulator updates (η')
/// 5. Validator key set updates (κ', λ')
/// 6. Dispute resolution (ψ')
/// 7. Service account updates (δ')
/// 8. Core allocation updates (ρ')
/// 9. Work report processing (W*)
/// 10. Accumulation of work reports (ready', accumulated', δ', χ', ι', φ', beefycommitmap)
/// 11. Authorization updates (α')
/// 12. Validator statistics updates (π')
///
/// The function processes various extrinsics and updates different components of
/// the state in a specific order to ensure consistency and proper execution of
/// the protocol rules. Each component update may depend on the results of
/// previous updates, forming a dependency graph that must be respected during
/// implementation.
///
/// This implementation should carefully follow the order and dependencies
/// outlined in the protocol specification to maintain the integrity and
/// correctness of the Jam blockchain state transitions.
const std = @import("std");
const Allocator = std.mem.Allocator;

const utils = @import("utils.zig");

const state = @import("state.zig");
const JamState = state.JamState;

const types = @import("types.zig");
const Block = types.Block;
const Header = types.Header;

const Params = @import("jam_params.zig").Params;

/// State Transition Function Implementation
///
/// This is a naive, sequential implementation of JAM's state transition function
/// that processes blocks in a straightforward manner, directly updating state
/// without optimizations for branching, reversals, or concurrent access.
///
/// Performance is not a primary concern in this initial implementation as it
/// assumes a clean, linear import of blocks without any forks or reorganizations.
/// The focus is on correctness and direct mapping to the protocol specification.
///
/// Future iterations will introduce more sophisticated data structures and
/// algorithms to handle:
/// - Chain reorganizations and forks
/// - Efficient state storage and retrieval
/// - Concurrent block processing
/// - Memory-efficient state updates
/// - Rollback capabilities
///
/// These optimizations will emerge naturally as the implementation progresses
/// and the specific performance requirements become clearer through real-world
/// usage patterns.
pub fn stateTransition(
    comptime params: Params,
    allocator: Allocator,
    current_state: *const JamState(params),
    new_block: *const Block,
) !JamState(params) {
    // NOTE: challenge with this state transition is to be able to update fields and make sure appropiate
    // memory is freed when doing so. As such, maybe its better to work with updates or deltas which will also
    // communicate what has changed. These deltas can then be applied to a JamState, and we can get a summary of what
    // has been changed.

    var new_state: JamState(params) = try JamState(params).init(allocator);

    // Step 1: Time Transition (τ')
    // Purpose: Update the blockchain's internal time based on the new block's header.
    // This step ensures that the blockchain's concept of time progresses with each new block.
    // It's crucial for maintaining the temporal order of events and for time-based protocol rules.
    if (current_state.tau) |tau| {
        new_state.tau = try transitionTime(
            allocator,
            tau,
            new_block.header,
        );
    } else {
        return error.UninitializedTau;
    }

    // Step 2: Recent History Transition (β')
    // Purpose: Update the recent history of blocks with information from the new block.
    // This maintains a rolling window of recent block data, which is essential for:
    // - Validating new blocks (e.g., checking parent hashes)
    // - Handling short-term chain reorganizations
    // - Providing context for other protocol operations
    // new_state.beta = try transitionRecentHistory(
    //     allocator,
    //     &current_state.beta,
    //     new_block,
    // );

    // NOTE: it seems safrole needs updated psi with offenders now
    // putting it here to make it work
    new_state.psi = try current_state.psi.?.deepClone();

    // Step 3-5: Safrole Consensus Mechanism Transition (γ', η', ι', κ', λ')
    // Purpose: Update the consensus-related state components based on the Safrole rules.
    // This step is crucial for maintaining the blockchain's consensus and includes:
    // - γ': Updating the current epoch's validator set and their states
    // - η': Updating the on-chain entropy accumulator for randomness
    // - ι': Modifying the upcoming validator set
    // - κ': Adjusting the current active validator set
    // - λ': Updating the set of validators from the previous epoch
    // These updates ensure the proper rotation and management of validators,
    // maintain the chain's randomness, and prepare for future epochs.
    var safrole_transition = try transitionSafrole(
        params,
        allocator,
        &current_state.gamma.?,
        &current_state.eta.?,
        &current_state.iota.?,
        &current_state.kappa.?,
        &current_state.lambda.?,
        &current_state.tau.?,
        &new_state.psi.?,
        new_block,
    );
    // NOTE: only deinit the markers as we are using rest of allocated
    // fiels in the new state
    defer safrole_transition.deinit_markers(allocator);

    // Extract state components from post_state
    new_state.gamma = .{
        .k = safrole_transition.post_state.gamma_k,
        .a = safrole_transition.post_state.gamma_a,
        .s = safrole_transition.post_state.gamma_s,
        .z = safrole_transition.post_state.gamma_z,
    };
    new_state.eta = safrole_transition.post_state.eta;
    new_state.iota = safrole_transition.post_state.iota;
    new_state.kappa = safrole_transition.post_state.kappa;
    new_state.lambda = safrole_transition.post_state.lambda;

    // Store markers if present
    // if (safrole_transition.epoch_marker) |marker| {
    //     try new_state.storeEpochMarker(allocator, marker);
    // }
    // if (safrole_transition.ticket_marker) |marker| {
    //     try new_state.storeTicketMarker(allocator, marker);
    // }

    // Step 6: Dispute Resolution Transition (ψ')
    // Purpose: Process and update the state related to disputes and judgments.
    // This step handles:
    // - Resolution of disputes about validator behavior or block validity
    // - Updates to the set of known valid or invalid blocks/transactions
    // - Potential slashing or penalty applications for misbehaving validators
    // It's crucial for maintaining the integrity and security of the network.
    // new_state.psi = try transitionDisputes(
    //     allocator,
    //     params.validators_count,
    //     &current_state.psi,
    //     &current_state.kappa,
    //     &current_state.lambda,
    //     new_block.extrinsic.disputes,
    // );

    // Step 7: Service Accounts Transition (δ')
    // Purpose: Update the state of service accounts, which are similar to smart contracts.
    // This step processes:
    // - New preimages submitted to the chain
    // - Updates to existing service account states
    // - Potential creation or deletion of service accounts
    // It's essential for maintaining the application layer of the blockchain.
    // new_state.delta = try transitionServiceAccounts(
    //     allocator,
    //     &current_state.delta,
    //     new_block.extrinsic.preimages,
    // );

    // Step 8: Core Allocations Transition (ρ')
    // Purpose: Update the state related to core assignments and work packages.
    // This step handles:
    // - Assigning new work packages to cores
    // - Processing guarantees and assurances for work packages
    // - Updating the status of ongoing work on each core
    // It's crucial for managing the computational resources of the network.
    // new_state.rho = try transitionCoreAllocations(
    //     allocator,
    //     &current_state.rho,
    //     new_block.extrinsic.assurances,
    //     new_block.extrinsic.guarantees,
    // );

    // Step 9-10: Work Report Accumulation (ready', accumulated', δ', χ', ι', φ', beefycommitmap)
    // Purpose: Process completed work reports and accumulate their results.
    // This complex step involves:
    // - Updating service account states (δ') based on work results
    // - Modifying privileged service identities (χ') if necessary
    // - Adjusting the upcoming validator set (ι') based on work outcomes
    // - Updating the authorization queue (φ')
    // - Creating a BEEFY commitment map for cross-chain validation
    // This step is central to the blockchain's ability to process and apply
    // the results of off-chain computation.

    // const accumulation_transition = try accumulateWorkReports(
    //     allocator,
    //     &current_state.delta,
    //     &current_state.chi,
    //     &current_state.iota,
    //     &current_state.phi,
    //     &new_state.rho,
    // );
    // new_state.delta = accumulation_transition.delta;
    // new_state.chi = accumulation_transition.chi;
    // new_state.iota = accumulation_transition.iota;
    // new_state.phi = accumulation_transition.phi;

    // Step 11: Authorization Updates (α')
    // Purpose: Update the core authorization state and associated queues.
    // This step handles:
    // - Processing new authorization requests
    // - Updating existing authorizations
    // - Managing the authorization queue for future blocks
    // It's crucial for controlling access to core resources and managing
    // the flow of work through the system.

    // new_state.alpha = try transitionAuthorizations(
    //     allocator,
    //     &current_state.alpha,
    //     &new_state.phi,
    //     new_block.extrinsic.guarantees,
    // );

    // Step 12: Validator Statistics Updates (π')
    // Purpose: Update performance metrics and statistics for validators.
    // This final step involves:
    // - Recording block production, guarantee, and assurance activities
    // - Updating stake, rewards, and penalty information
    // - Calculating and storing performance indicators
    // These statistics are crucial for the proper functioning of the
    // proof-of-stake system and for incentivizing good validator behavior.

    // new_state.pi = try transitionValidatorStatistics(
    //     allocator,
    //     &current_state.pi,
    //     new_block,
    //     &new_state.kappa,
    // );

    return new_state;
}

pub fn transitionTime(
    allocator: Allocator,
    current_tau: state.Tau,
    header: Header,
) !state.Tau {
    _ = allocator;
    _ = current_tau;
    // Transition τ based on the new block's header
    // TODO: do some checking
    return header.slot;
}

pub fn transitionRecentHistory(
    allocator: Allocator,
    current_beta: *const state.Beta,
    new_block: *const Block,
) !state.Beta {
    const RecentBlock = @import("recent_blocks.zig").RecentBlock;
    // Transition β with information from the new block
    var new_beta = try current_beta.deepClone(allocator);
    try new_beta.import(allocator, try RecentBlock.fromBlock(allocator, new_block));
    return new_beta;
}

// TODO: now worth to be a function
pub fn getBlockEntropy(
    header: *const types.Header,
) types.BandersnatchVrfOutput {
    const vrf = @import("vrf.zig");
    return vrf.getVrfOutput(&header.entropy_source);
}

const safrole = @import("safrole.zig");
pub fn transitionSafrole(
    comptime params: Params,
    allocator: Allocator,
    current_gamma: *const state.Gamma(params.validators_count, params.epoch_length),
    current_eta: *const state.Eta,
    current_iota: *const state.Iota,
    current_kappa: *const state.Kappa,
    current_lambda: *const state.Lambda,
    current_tau: *const state.Tau,
    post_psi: *const state.Psi,
    new_block: *const Block,
) !safrole.Result {

    // Verify the entropy source signature from the block header
    const entropy = getBlockEntropy(
        &new_block.header,
    );
    // Prepare safrole input from block
    const input = .{
        .slot = new_block.header.slot,
        .entropy = entropy,
        .extrinsic = new_block.extrinsic.tickets,
    };

    // Prepare current safrole state
    const safrole_state = .{
        .tau = current_tau.*,
        .eta = current_eta.*,
        .lambda = current_lambda.*,
        .kappa = current_kappa.*,
        .gamma_k = current_gamma.k,
        .iota = current_iota.*,
        .gamma_a = current_gamma.a,
        .gamma_s = current_gamma.s,
        .gamma_z = current_gamma.z,
    };

    const offenders = try post_psi.offenders(allocator);
    defer allocator.free(offenders);

    // Call safrole transition
    return try safrole.transition(
        allocator,
        params,
        safrole_state,
        input.slot,
        // TODO: get the entropy out of the entropy source
        input.entropy,
        input.extrinsic,
        offenders,
    );
}

fn validator_key(validator: types.ValidatorData) types.Ed25519Public {
    return validator.ed25519;
}

pub fn transitionDisputes(
    comptime validators_count: u32,
    comptime core_count: u16,
    allocator: Allocator,
    current_psi: *const state.Psi,
    current_kappa: state.Kappa,
    current_lambda: state.Lambda,
    current_rho: *state.Rho(core_count),
    current_epoch: types.Epoch,
    xtdisputes: types.DisputesExtrinsic,
) !state.Psi {
    // Map current_kappa to extract Edwards public keys
    const current_kappa_keys = try utils.mapAlloc(
        types.ValidatorData,
        types.Ed25519Public,
        allocator,
        current_kappa.items(),
        validator_key,
    );
    defer allocator.free(current_kappa_keys);

    const current_lambda_keys = try utils.mapAlloc(
        types.ValidatorData,
        types.Ed25519Public,
        allocator,
        current_lambda.items(),
        validator_key,
    );
    defer allocator.free(current_lambda_keys);

    const disputes = @import("disputes.zig");

    // Verify correctness of the disputes extrinsic
    try disputes.verifyDisputesExtrinsicPre(
        xtdisputes,
        current_psi,
        current_kappa_keys,
        current_lambda_keys,
        validators_count,
        current_epoch,
    );

    // Transition ψ based on new disputes
    var posterior_state = try disputes.processDisputesExtrinsic(core_count, current_psi, current_rho, xtdisputes, validators_count);
    errdefer posterior_state.deinit();

    // Verify correctness of the updated state after processing disputes
    try disputes.verifyDisputesExtrinsicPost(xtdisputes, &posterior_state);

    return posterior_state;
}

pub fn transitionServiceAccounts(
    allocator: Allocator,
    current_delta: *const state.Delta,
    xtpreimages: types.PreimagesExtrinsic,
) !state.Delta {
    _ = allocator;
    _ = current_delta;
    _ = xtpreimages;
    // Transition δ with new preimages
}

pub fn transitionCoreAllocations(
    allocator: Allocator,
    current_rho: *const state.Rho,
    xtassurances: types.AssurancesExtrinsic,
    xtguarantees: types.GuaranteesExtrinsic,
) !state.Rho {
    _ = allocator;
    _ = current_rho;
    _ = xtassurances;
    _ = xtguarantees;
    // Transition ρ based on new assurances and guarantees
}

pub fn accumulateWorkReports(
    allocator: Allocator,
    current_delta: *const state.Delta,
    current_chi: *const state.Chi,
    current_iota: *const state.Iota,
    current_phi: *const state.Phi,
    updated_rho: *const state.Rho,
) !struct { delta: state.Delta, chi: state.Chi, iota: state.Iota, phi: state.Phi } {
    _ = allocator;
    _ = current_delta;
    _ = current_chi;
    _ = current_iota;
    _ = current_phi;
    _ = updated_rho;
    // Process work reports and transition δ, χ, ι, and φ
}

pub fn transitionAuthorizations(
    allocator: Allocator,
    current_alpha: *const state.Alpha,
    updated_phi: *const state.Phi,
    xtguarantees: types.GuaranteesExtrinsic,
) !state.Alpha {
    _ = allocator;
    _ = current_alpha;
    _ = updated_phi;
    _ = xtguarantees;
    // Transition α based on new authorizations
}

pub fn transitionValidatorStatistics(
    allocator: Allocator,
    current_pi: *const state.Pi,
    new_block: Block,
    updated_kappa: *const state.Kappa,
) !state.Pi {
    _ = allocator;
    _ = current_pi;
    _ = new_block;
    _ = updated_kappa;
    // Transition π with new validator statistics
}
