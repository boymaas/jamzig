const std = @import("std");
const types = @import("types.zig");
const jam_params = @import("jam_params.zig");
const JamState = @import("state.zig").JamState;
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");
const io = @import("io.zig");

const tracing = @import("tracing");
const trace = tracing.scoped(.stf);
const tracy = @import("tracy");

// Constants for seal contexts
const SEAL_CONTEXT_TICKET = "jam_ticket_seal";
const SEAL_CONTEXT_FALLBACK = "jam_fallback_seal";
const ENTROPY_CONTEXT = "jam_entropy";
const MAX_CONTEXT_BUFFER_SIZE = 64;

/// Errors specific to header validation
pub const HeaderValidationError = error{
    // Structural validation errors
    InvalidParentHash,
    InvalidPriorStateRoot,
    InvalidExtrinsicHash,

    // Timing validation errors
    FutureBlock,
    SlotNotGreaterThanParent,
    BlockTooOld,
    ExcessiveSlotGap,

    // Author validation errors
    InvalidAuthorIndex,
    AuthorNotInValidatorSet,

    // Seal validation errors
    TicketSealVerificationFailed,
    FallbackSealVerificationFailed,
    InvalidTicketId,
    InvalidSealMode,

    // Entropy validation errors
    InvalidEntropySource,
    EntropySourceVerificationFailed,

    // Marker validation errors
    InvalidEpochBoundary,
    InvalidEpochMarkerTiming,
    InvalidTicketsMarkerTiming,
    InvalidOffendersMark,

    // General errors
    OutOfMemory,
    InvalidHeader,
    StateNotInitialized,
};

/// Configuration for header validation
pub const ValidationConfig = struct {
    /// Maximum allowed clock drift in seconds for future block protection
    max_clock_drift_seconds: u32 = 30,

    /// Maximum age in seconds before a block is considered too old
    max_block_age_seconds: u32 = 24 * 60 * 60, // 24 hours

    /// Maximum allowed slot gap between parent and current block
    max_slot_gap: u32 = 1024,
};

/// Context for seal validation
pub const SealContext = struct {
    /// The header being validated
    header: *const types.Header,
    /// The author's public key
    author_key: types.BandersnatchPublic,
    /// The entropy value to use
    entropy: types.Entropy,
    /// Optional tickets (if in ticket mode)
    tickets: ?[]const types.TicketBody,
    /// The context prefix (SEAL_CONTEXT_TICKET or SEAL_CONTEXT_FALLBACK)
    context_prefix: []const u8,
};

/// Result of header validation
pub const ValidationResult = struct {
    /// Whether the header was validated successfully
    success: bool,
    /// Whether the block was sealed with tickets
    sealed_with_tickets: bool,
};

/// Header validator with state-based validation
pub fn HeaderValidator(comptime IOExecutor: type, comptime params: jam_params.Params) type {
    return struct {
        allocator: std.mem.Allocator,
        config: ValidationConfig,
        executor: *IOExecutor,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, executor: *IOExecutor) Self {
            return .{
                .allocator = allocator,
                .config = ValidationConfig{},
                .executor = executor,
            };
        }

        pub fn initWithConfig(allocator: std.mem.Allocator, executor: *IOExecutor, config: ValidationConfig) Self {
            return .{
                .allocator = allocator,
                .config = config,
                .executor = executor,
            };
        }

        /// Worker function for parallel seal validation
        fn validateSealWorker(
            self: *Self,
            ctx: SealContext,
        ) !void {
            try self.validateSeal(ctx);
        }

        /// Worker function for parallel entropy source validation
        fn validateEntropySourceWorker(
            self: *Self,
            header: *const types.Header,
            author_key: types.BandersnatchPublic,
            sealed_with_tickets: bool,
        ) !void {
            try self.validateEntropySource(header, author_key, sealed_with_tickets);
        }

        /// Main entry point for header validation
        pub fn validateHeader(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
            current_state_root: types.StateRoot,
            extrinsics: *const types.Extrinsic,
        ) !ValidationResult {
            const span = trace.span(@src(), .validate_header);
            defer span.deinit();

            // Ensure state is initialized (only debugbuilds)
            _ = try state.debugCheckIfFullyInitialized();

            const time = params.Time().init(state.tau.?, header.slot);
            span.debug("Time initialized: {}", .{time});

            // Phase:  Select appropriate entropy
            const eta_prime = self.selectEntropy(state, header);

            // Phase: Determine ticket availability
            var tickets = try self.resolveTickets(state, header);
            defer tickets.deinit(self.allocator);

            // Phase: Author validation (needs ticket information)
            // Pass gamma.s for fallback mode key verification
            const author_key =
                try self.validateAuthorConstraints(state, header, eta_prime, tickets.tickets, state.gamma.?.s);

            {
                // Parallel signature verification using WorkGroup
                // Create WorkGroup for parallel execution
                var work_group = self.executor.createGroup();
                defer work_group.deinit();

                // Prepare seal context
                const seal_context = SealContext{
                    .header = header,
                    .author_key = author_key,
                    .entropy = eta_prime[3],
                    .tickets = tickets.tickets,
                    .context_prefix = if (tickets.tickets != null) SEAL_CONTEXT_TICKET else SEAL_CONTEXT_FALLBACK,
                };

                // Spawn seal verification task
                try work_group.spawn(validateSealWorker, .{
                    self,
                    seal_context,
                });

                // Spawn entropy verification task
                try work_group.spawn(validateEntropySourceWorker, .{
                    self,
                    header,
                    author_key,
                    tickets.tickets != null,
                });

                // Wait for both tasks and propagate any errors (fail-fast built into WorkGroup)
                // NOTE: we cannot optimize this by placeing this below for example structural
                // validation because we need to ensure both tasks complete before we return otherwise
                // structural validation could fail and and memory pointed to would be freed. Or we should ensure
                // contexts are owned copies and we can safely ignore the threads.
                try work_group.waitAndCheckErrors();
            }

            // Phase: Structural validation
            try self.validateStructuralConstraints(state, header, current_state_root, extrinsics);

            // Phase: Timing validation
            try self.validateTimingConstraints(state, header);

            // Phase: Marker timing validation
            try self.validateMarkerTiming(state, header, extrinsics);

            return ValidationResult{
                .success = true,
                .sealed_with_tickets = tickets.tickets != null,
            };
        }

        /// Validate immediate structural properties
        fn validateStructuralConstraints(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
            current_state_root: types.StateRoot,
            extrinsics: *const types.Extrinsic,
        ) !void {
            const span = trace.span(@src(), .validate_structural_constraints);
            defer span.deinit();

            // Validate parent hash
            {
                const parent_span = span.child(@src(), .parent_hash);
                defer parent_span.deinit();
                if (state.beta) |beta| {
                    const last_block_hash = beta.getLastBlockHash();
                    if (!std.mem.eql(u8, &header.parent, &last_block_hash)) {
                        span.err("Parent hash mismatch: header={s}, state={s}", .{
                            std.fmt.fmtSliceHexLower(&header.parent),
                            std.fmt.fmtSliceHexLower(&last_block_hash),
                        });
                        return HeaderValidationError.InvalidParentHash;
                    }
                }
            }

            // Validate prior state root
            {
                const state_root_span = span.child(@src(), .prior_state_root);
                defer state_root_span.deinit();
                if (!std.mem.eql(u8, &header.parent_state_root, &current_state_root)) {
                    span.err("Prior state root mismatch: header={s}, computed={s}", .{
                        std.fmt.fmtSliceHexLower(&header.parent_state_root),
                        std.fmt.fmtSliceHexLower(&current_state_root),
                    });
                    return HeaderValidationError.InvalidPriorStateRoot;
                }
            }

            // Validate extrinsic hash
            {
                const extrinsic_span = span.child(@src(), .extrinsic_hash);
                defer extrinsic_span.deinit();
                const computed_hash = try extrinsics.calculateHash(params, self.allocator);
                if (!std.mem.eql(u8, &header.extrinsic_hash, &computed_hash)) {
                    span.err("Extrinsic hash mismatch: header={s}, computed={s}", .{
                        std.fmt.fmtSliceHexLower(&header.extrinsic_hash),
                        std.fmt.fmtSliceHexLower(&computed_hash),
                    });
                    return HeaderValidationError.InvalidExtrinsicHash;
                }
            }
        }

        /// Validate timing constraints
        fn validateTimingConstraints(
            _: *Self,
            state: *const JamState(params),
            header: *const types.Header,
        ) !void {
            const span = trace.span(@src(), .validate_timing);
            defer span.deinit();

            const tau = state.tau.?;

            // Check slot ordering
            if (header.slot <= tau) {
                span.err("Header slot {d} not greater than state slot {d}", .{ header.slot, tau });
                return HeaderValidationError.SlotNotGreaterThanParent;
            }

            // Check for excessive slot gaps
            // DISABLED: I cannot see this in the GP explicitly mentioned
            // const slot_gap = header.slot - tau;
            // if (slot_gap > self.config.max_slot_gap) {
            //     span.err("Slot gap {d} exceeds maximum {d}", .{ slot_gap, self.config.max_slot_gap });
            //     return HeaderValidationError.ExcessiveSlotGap;
            // }
        }

        /// Validate author constraints and return author key
        fn validateAuthorConstraints(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
            eta_prime: types.Eta,
            tickets: ?[]const types.TicketBody,
            gamma_s: types.GammaS,
        ) !types.BandersnatchPublic {
            _ = self;
            const span = trace.span(@src(), .validate_author_constraints);
            defer span.deinit();

            // Determine which validator set to use based on epoch transition
            // According to graypaper: use posterior κ' which at epoch boundaries is γ_k
            const time = params.Time().init(state.tau.?, header.slot);
            const validators = if (time.isNewEpoch())
                // TODO: gamma_k is no gamma_pedning
                state.gamma.?.k.validators // Use gamma.k for first block of new epoch
            else
                state.kappa.?.validators; // Use kappa for regular blocks

            // Validate author index
            if (header.author_index >= validators.len) {
                span.err("Author index {d} out of bounds (max: {d})", .{
                    header.author_index,
                    validators.len - 1,
                });
                return HeaderValidationError.InvalidAuthorIndex;
            }

            // Author validation depends on whether we're in ticket mode or fallback mode
            if (tickets) |ticket_list| {
                // TICKET MODE: Author is self-declared via header.author_index
                // The seal verification will prove they own the winning ticket
                // (Only the ticket owner can produce a seal with matching ticket ID)
                span.debug("Validating author in ticket mode", .{});

                const winning_ticket = ticket_list[time.current_slot_in_epoch];
                _ = winning_ticket;

                span.debug("Ticket mode: author claims index {d}, ownership verified via seal", .{header.author_index});
            } else {
                // FALLBACK MODE: Verify author key matches γ_s'[m'] as per graypaper
                // Graypaper eq:slotkeysequence:
                //   γ_s' = γ_s when e' = e (same epoch - use stored keys)
                //   γ_s' = F(η'_2, κ') otherwise (epoch boundary - recompute)
                span.debug("Validating author in fallback mode", .{});

                const author_key = validators[header.author_index].bandersnatch;

                if (time.isSameEpoch()) {
                    // Same epoch: use stored gamma.s.keys
                    const expected_key = switch (gamma_s) {
                        .keys => |keys| keys[time.current_slot_in_epoch],
                        .tickets => {
                            // This shouldn't happen - if we have tickets, we should be in ticket mode
                            span.err("Fallback mode entered but gamma.s contains tickets", .{});
                            return HeaderValidationError.InvalidAuthorIndex;
                        },
                    };

                    if (!std.mem.eql(u8, &expected_key, &author_key)) {
                        span.err("Fallback mode: author key mismatch at slot {d}", .{time.current_slot_in_epoch});
                        span.err("Expected key: {s}", .{std.fmt.fmtSliceHexLower(&expected_key)});
                        span.err("Got key:      {s}", .{std.fmt.fmtSliceHexLower(&author_key)});
                        return HeaderValidationError.InvalidAuthorIndex;
                    }
                } else {
                    // Epoch boundary: compute expected author with F(η'_2, κ')
                    // The expected author index is derived from entropy
                    const expected_index = @import("safrole/epoch_handler.zig").deriveKeyIndex(
                        eta_prime[2],
                        time.current_slot_in_epoch,
                        validators.len,
                    );

                    if (expected_index != header.author_index) {
                        span.err("Fallback mode (epoch boundary): expected author index {d}, got {d}", .{ expected_index, header.author_index });
                        return HeaderValidationError.InvalidAuthorIndex;
                    }
                }

                span.debug("Fallback mode author validation passed: slot={d}", .{time.current_slot_in_epoch});
            }

            return validators[header.author_index].bandersnatch;
        }

        /// Validate marker timing based on state
        fn validateMarkerTiming(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
            extrinsics: *const types.Extrinsic,
        ) !void {
            _ = self;
            const span = trace.span(@src(), .validate_marker_timing);
            defer span.deinit();

            const tau = state.tau.?;
            const transition_time = params.Time().init(tau, header.slot);

            // Check epoch marker timing
            const should_have_epoch_marker = transition_time.isNewEpoch();
            const has_epoch_marker = header.epoch_mark != null;

            if (should_have_epoch_marker and !has_epoch_marker) {
                span.err("New epoch but epoch marker missing", .{});
                return HeaderValidationError.InvalidEpochMarkerTiming;
            }

            if (!should_have_epoch_marker and has_epoch_marker) {
                span.err("Epoch marker present but not new epoch", .{});
                return HeaderValidationError.InvalidEpochMarkerTiming;
            }

            // Check tickets marker timing
            if (transition_time.didCrossTicketSubmissionEndInSameEpoch() and
                // TODO: make a nice accessor for this
                state.gamma.?.a.len == params.epoch_length)
            {
                // When crossing ticket submission end, and our ticket
                // accumulator is full tickets_mark is REQUIRED
                if (header.tickets_mark == null) {
                    span.err("Missing required tickets marker when crossing ticket submission end", .{});
                    return HeaderValidationError.InvalidTicketsMarkerTiming;
                }
            } else if (header.tickets_mark != null) {
                span.err("Tickets marker present but we did not cross didCrossTicketSubmissionEnd", .{});
                return HeaderValidationError.InvalidTicketsMarkerTiming;
            }

            // Validate offenders mark matches disputes extrinsic (graypaper judgments.tex)
            // Note: This is a preliminary check - we can only verify it's empty when disputes is empty
            // Full validation requires processing disputes first, which happens in STF
            // For now, we enforce the basic structural constraint
            if (extrinsics.disputes.culprits.len == 0 and extrinsics.disputes.faults.len == 0) {
                if (header.offenders_mark.len > 0) {
                    span.err("Offenders mark not empty but no culprits or faults in disputes extrinsic", .{});
                    return HeaderValidationError.InvalidOffendersMark;
                }
            }
        }

        /// Result of ticket resolution
        const TicketResolution = struct {
            tickets: ?[]const types.TicketBody,
            needs_cleanup: bool,

            pub fn deinit(self: *TicketResolution, allocator: std.mem.Allocator) void {
                if (self.tickets) |tickets| {
                    if (self.needs_cleanup)
                        allocator.free(tickets);
                }
            }
        };

        /// Resolve ticket availability
        fn resolveTickets(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
        ) !TicketResolution {
            const span = trace.span(@src(), .resolve_tickets);
            defer span.deinit();

            const time = params.Time().init(state.tau.?, header.slot);

            // Determine if we are in ticketmode
            var needs_cleanup = false;
            const tickets: ?[]types.TicketBody =
                // When we are on the boundary
                if (time.priorWasInTicketSubmissionTail() and
                time.isConsecutiveEpoch()) brl: {
                    if (state.gamma.?.a.len == params.epoch_length) {
                        needs_cleanup = true;
                        break :brl try @import("safrole/ordering.zig").outsideInOrdering(types.TicketBody, self.allocator, state.gamma.?.a);
                    } else {
                        break :brl null;
                    }
                    // As long as we are in the same epoch, use tickets
                } else if (time.isSameEpoch() and state.gamma.?.s == .tickets)
                    state.gamma.?.s.tickets
                else
                    // If we skipped an epoch or anything else fallback
                    null;

            // No tickets available
            return TicketResolution{
                .tickets = tickets,
                .needs_cleanup = needs_cleanup,
            };
        }

        /// Select appropriate entropy based on timing
        fn selectEntropy(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
        ) types.Eta {
            _ = self;
            const span = trace.span(@src(), .select_entropy);
            defer span.deinit();

            const time = params.Time().init(state.tau.?, header.slot);
            const entropy_buffer = state.eta.?;

            if (time.isNewEpoch()) {
                return [4][32]u8{ [_]u8{0} ** 32, entropy_buffer[0], entropy_buffer[1], entropy_buffer[2] };
            } else {
                return entropy_buffer;
            }
        }

        /// Unified seal validation
        fn validateSeal(self: *Self, ctx: SealContext) !void {
            const span = trace.span(@src(), .validate_seal);
            defer span.deinit();

            // Serialize unsigned header
            const unsigned_header_bytes = blk: {
                const unsigned_header = types.HeaderUnsigned.fromHeaderShared(ctx.header);
                break :blk try codec.serializeAlloc(
                    types.HeaderUnsigned,
                    params,
                    self.allocator,
                    unsigned_header,
                );
            };
            defer self.allocator.free(unsigned_header_bytes);

            // Extract seal signature
            const seal_signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(ctx.header.seal);

            // Build context buffer
            const context_bytes = blk: {
                const context_span = span.child(@src(), .seal_build_context);
                defer context_span.deinit();
                var context_buf: [MAX_CONTEXT_BUFFER_SIZE]u8 = undefined;
                var context_len: usize = 0;

                // Add context prefix
                @memcpy(context_buf[context_len .. context_len + ctx.context_prefix.len], ctx.context_prefix);
                context_len += ctx.context_prefix.len;

                // Add entropy
                @memcpy(context_buf[context_len .. context_len + 32], &ctx.entropy);
                context_len += 32;

                // Handle ticket-specific validation
                if (ctx.tickets) |ticket_bodies| {
                    const ticket_span = span.child(@src(), .seal_validate_ticket);
                    defer ticket_span.deinit();
                    const slot_in_epoch = ctx.header.slot % params.epoch_length;
                    const ticket = ticket_bodies[slot_in_epoch];

                    // Verify VRF output matches ticket ID
                    const seal_vrf_output = seal_signature.outputHash() catch {
                        span.err("Failed to extract VRF output from seal", .{});
                        return HeaderValidationError.TicketSealVerificationFailed;
                    };

                    if (!std.mem.eql(u8, &ticket.id, &seal_vrf_output)) {
                        span.err("Ticket ID mismatch: Ticket ID={s}, VRF output={s}", .{
                            std.fmt.fmtSliceHexLower(&ticket.id),
                            std.fmt.fmtSliceHexLower(&seal_vrf_output),
                        });
                        return HeaderValidationError.InvalidTicketId;
                    }

                    // Add ticket attempt to context
                    context_buf[context_len] = ticket.attempt;
                    context_len += 1;
                }

                break :blk context_buf[0..context_len];
            };

            // Verify signature
            {
                const verify_span = span.child(@src(), .seal_verify_signature);
                defer verify_span.deinit();
                const public_key = crypto.bandersnatch.Bandersnatch.PublicKey.fromBytes(ctx.author_key);
                _ = seal_signature.verify(
                    context_bytes,
                    unsigned_header_bytes,
                    public_key,
                ) catch {
                    const err = if (ctx.tickets != null)
                        HeaderValidationError.TicketSealVerificationFailed
                    else
                        HeaderValidationError.FallbackSealVerificationFailed;
                    span.err("{s} seal verification failed", .{ctx.context_prefix});
                    return err;
                };
            }

            span.debug("Seal verification successful (mode: {s})", .{ctx.context_prefix});
        }

        /// Validate VRF entropy source
        fn validateEntropySource(
            self: *Self,
            header: *const types.Header,
            author_key: types.BandersnatchPublic,
            sealed_with_tickets: bool,
        ) !void {
            _ = self;
            _ = sealed_with_tickets;
            const span = trace.span(@src(), .validate_entropy_source);
            defer span.deinit();

            // Parse seal signature to get VRF output
            const seal_output_hash = blk: {
                const seal_output_hash_span = span.child(@src(), .entropy_extract_seal_output);
                defer seal_output_hash_span.deinit();
                const seal_signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.seal);
                break :blk seal_signature.outputHash() catch {
                    span.err("Failed to extract seal output hash", .{});
                    return HeaderValidationError.InvalidEntropySource;
                };
            };

            // Build context: ENTROPY_CONTEXT ⌢ Y(Hs)
            const context_bytes = blk: {
                var context_buf: [MAX_CONTEXT_BUFFER_SIZE]u8 = undefined;
                var context_len: usize = 0;

                @memcpy(context_buf[context_len .. context_len + ENTROPY_CONTEXT.len], ENTROPY_CONTEXT);
                context_len += ENTROPY_CONTEXT.len;

                @memcpy(context_buf[context_len .. context_len + 32], &seal_output_hash);
                context_len += 32;

                break :blk context_buf[0..context_len];
            };

            // Verify entropy source signature
            {
                const verify_span = span.child(@src(), .entropy_verify_signature);
                defer verify_span.deinit();
                const entropy_signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.entropy_source);
                const public_key = crypto.bandersnatch.Bandersnatch.PublicKey.fromBytes(author_key);
                _ = entropy_signature.verify(
                    context_bytes,
                    &[_]u8{}, // Empty message for VRF
                    public_key,
                ) catch {
                    span.err("Entropy source verification failed", .{});
                    return HeaderValidationError.EntropySourceVerificationFailed;
                };
            }

            span.debug("Entropy source verification successful", .{});
        }
    };
}
