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

pub fn stateTransition(allocator: Allocator, params: Params, current_state: *const JamState, new_block: Block) !JamState {
    var new_state: JamState = undefined;

    // Step 1: Time Transition (τ')
    // Purpose: Update the blockchain's internal time based on the new block's header.
    // This step ensures that the blockchain's concept of time progresses with each new block.
    // It's crucial for maintaining the temporal order of events and for time-based protocol rules.
    new_state.tau = try transitionTime(
        allocator,
        &current_state.tau,
        new_block.header,
    );

    // Step 2: Recent History Transition (β')
    // Purpose: Update the recent history of blocks with information from the new block.
    // This maintains a rolling window of recent block data, which is essential for:
    // - Validating new blocks (e.g., checking parent hashes)
    // - Handling short-term chain reorganizations
    // - Providing context for other protocol operations
    new_state.beta = try transitionRecentHistory(
        allocator,
        &current_state.beta,
        new_block,
    );

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
    const safrole_transition = try transitionSafrole(
        allocator,
        &current_state.gamma,
        &current_state.eta,
        &current_state.iota,
        &current_state.kappa,
        &current_state.lambda,
        &current_state.tau,
        new_block,
    );
    new_state.gamma = safrole_transition.gamma;
    new_state.eta = safrole_transition.eta;
    new_state.iota = safrole_transition.iota;
    new_state.kappa = safrole_transition.kappa;
    new_state.lambda = safrole_transition.lambda;

    // Step 6: Dispute Resolution Transition (ψ')
    // Purpose: Process and update the state related to disputes and judgments.
    // This step handles:
    // - Resolution of disputes about validator behavior or block validity
    // - Updates to the set of known valid or invalid blocks/transactions
    // - Potential slashing or penalty applications for misbehaving validators
    // It's crucial for maintaining the integrity and security of the network.
    new_state.psi = try transitionDisputes(
        allocator,
        params.validators_count,
        &current_state.psi,
        &current_state.kappa,
        &current_state.lambda,
        new_block.extrinsic.disputes,
    );

    // Step 7: Service Accounts Transition (δ')
    // Purpose: Update the state of service accounts, which are similar to smart contracts.
    // This step processes:
    // - New preimages submitted to the chain
    // - Updates to existing service account states
    // - Potential creation or deletion of service accounts
    // It's essential for maintaining the application layer of the blockchain.
    new_state.delta = try transitionServiceAccounts(
        allocator,
        &current_state.delta,
        new_block.extrinsic.preimages,
    );

    // Step 8: Core Allocations Transition (ρ')
    // Purpose: Update the state related to core assignments and work packages.
    // This step handles:
    // - Assigning new work packages to cores
    // - Processing guarantees and assurances for work packages
    // - Updating the status of ongoing work on each core
    // It's crucial for managing the computational resources of the network.
    new_state.rho = try transitionCoreAllocations(
        allocator,
        &current_state.rho,
        new_block.extrinsic.assurances,
        new_block.extrinsic.guarantees,
    );

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
    const accumulation_transition = try accumulateWorkReports(
        allocator,
        &current_state.delta,
        &current_state.chi,
        &current_state.iota,
        &current_state.phi,
        &new_state.rho,
    );
    new_state.delta = accumulation_transition.delta;
    new_state.chi = accumulation_transition.chi;
    new_state.iota = accumulation_transition.iota;
    new_state.phi = accumulation_transition.phi;

    // Step 11: Authorization Updates (α')
    // Purpose: Update the core authorization state and associated queues.
    // This step handles:
    // - Processing new authorization requests
    // - Updating existing authorizations
    // - Managing the authorization queue for future blocks
    // It's crucial for controlling access to core resources and managing
    // the flow of work through the system.
    new_state.alpha = try transitionAuthorizations(
        allocator,
        &current_state.alpha,
        &new_state.phi,
        new_block.extrinsic.guarantees,
    );

    // Step 12: Validator Statistics Updates (π')
    // Purpose: Update performance metrics and statistics for validators.
    // This final step involves:
    // - Recording block production, guarantee, and assurance activities
    // - Updating stake, rewards, and penalty information
    // - Calculating and storing performance indicators
    // These statistics are crucial for the proper functioning of the
    // proof-of-stake system and for incentivizing good validator behavior.
    new_state.pi = try transitionValidatorStatistics(
        allocator,
        &current_state.pi,
        new_block,
        &new_state.kappa,
    );

    return new_state;
}

pub fn transitionTime(
    allocator: Allocator,
    current_tau: *const state.Tau,
    header: Header,
) !state.Tau {
    _ = allocator;
    _ = current_tau;
    _ = header;
    // Transition τ based on the new block's header
}

pub fn transitionRecentHistory(
    allocator: Allocator,
    current_beta: *const state.Beta,
    new_block: Block,
) !state.Beta {
    _ = allocator;
    _ = current_beta;
    _ = new_block;
    // Transition β with information from the new block
}

pub fn transitionSafrole(
    allocator: Allocator,
    current_gamma: *const state.Gamma,
    current_eta: *const state.Eta,
    current_iota: *const state.Iota,
    current_kappa: *const state.Kappa,
    current_lambda: *const state.Lambda,
    current_tau: *const state.Tau,
    new_block: Block,
) !struct { gamma: state.Gamma, eta: state.Eta, iota: state.Iota, kappa: state.Kappa, lambda: state.Lambda } {
    // Prepare safrole input from block
    const input = .{
        .slot = new_block.header.slot,
        .entropy = new_block.header.entropy_source,
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

    // Call safrole transition
    const result = try @import("safrole.zig").transition(allocator, safrole_state, input);

    // Return updated state components
    return .{
        .gamma = .{
            .k = result.post_state.gamma_k,
            .a = result.post_state.gamma_a,
            .s = result.post_state.gamma_s,
            .z = result.post_state.gamma_z,
        },
        .eta = result.post_state.eta,
        .iota = result.post_state.iota,
        .kappa = result.post_state.kappa,
        .lambda = result.post_state.lambda,
    };
}

fn validator_key(validator: types.ValidatorData) types.Ed25519Key {
    return validator.ed25519;
}

pub fn transitionDisputes(
    allocator: Allocator,
    validator_count: usize,
    current_psi: *const state.Psi,
    current_kappa: state.Kappa,
    current_lambda: state.Lambda,
    current_rho: *state.Rho,
    current_epoch: types.Epoch,
    xtdisputes: types.DisputesExtrinsic,
) !state.Psi {
    // Map current_kappa to extract Edwards public keys
    const current_kappa_keys = try utils.mapAlloc(
        types.ValidatorData,
        types.Ed25519Key,
        allocator,
        current_kappa,
        validator_key,
    );
    defer allocator.free(current_kappa_keys);

    const current_lambda_keys = try utils.mapAlloc(
        types.ValidatorData,
        types.Ed25519Key,
        allocator,
        current_lambda,
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
        validator_count,
        current_epoch,
    );

    // Transition ψ based on new disputes
    var posterior_state = try disputes.processDisputesExtrinsic(current_psi, current_rho, xtdisputes, validator_count);
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
