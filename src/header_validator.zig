const std = @import("std");
const types = @import("types.zig");
const jam_params = @import("jam_params.zig");
const JamState = @import("state.zig").JamState;
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.header_validator);

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
    /// The entropy that was used for validation
    entropy_used: ?types.Entropy = null,
};

/// Header validator with state-based validation
pub fn HeaderValidator(comptime params: jam_params.Params) type {
    return struct {
        allocator: std.mem.Allocator,
        config: ValidationConfig,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .config = ValidationConfig{},
            };
        }

        pub fn initWithConfig(allocator: std.mem.Allocator, config: ValidationConfig) Self {
            return .{
                .allocator = allocator,
                .config = config,
            };
        }

        /// Main entry point for header validation
        pub fn validateHeader(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
            current_state_root: types.StateRoot,
            extrinsics: *const types.Extrinsic,
        ) !ValidationResult {
            const span = trace.span(.validate_header);
            defer span.deinit();

            // Ensure state is initialized (only debugbuilds)
            _ = try state.debugCheckIfFullyInitialized();

            // Phase 1: Structural validation
            try self.validateStructuralConstraints(state, header, current_state_root, extrinsics);

            // Phase 2: Timing validation
            try self.validateTimingConstraints(state, header);

            // Phase 3: Author validation
            const author_key = try self.validateAuthorConstraints(state, header);

            // Phase 4: Marker timing validation
            try self.validateMarkerTiming(state, header);

            // Phase 5: Determine ticket availability
            var tickets = try self.resolveTickets(state, header);
            defer tickets.deinit(self.allocator);

            // Phase 6: Select appropriate entropy
            const entropy = self.selectEntropy(state, header);

            // Phase 7: Validate seal
            const seal_context = SealContext{
                .header = header,
                .author_key = author_key,
                .entropy = entropy,
                .tickets = tickets.tickets,
                .context_prefix = if (tickets.tickets != null) SEAL_CONTEXT_TICKET else SEAL_CONTEXT_FALLBACK,
            };

            try self.validateSeal(seal_context);

            // Phase 8: Validate entropy source
            try self.validateEntropySource(header, author_key, tickets.tickets != null);

            return ValidationResult{
                .success = true,
                .sealed_with_tickets = tickets.tickets != null,
                .entropy_used = entropy,
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
            const span = trace.span(.validate_structural);
            defer span.deinit();

            // Validate parent hash
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

            // Validate prior state root
            if (!std.mem.eql(u8, &header.parent_state_root, &current_state_root)) {
                span.err("Prior state root mismatch: header={s}, computed={s}", .{
                    std.fmt.fmtSliceHexLower(&header.parent_state_root),
                    std.fmt.fmtSliceHexLower(&current_state_root),
                });
                return HeaderValidationError.InvalidPriorStateRoot;
            }

            // Validate extrinsic hash
            const computed_hash = try extrinsics.calculateHash(params, self.allocator);
            if (!std.mem.eql(u8, &header.extrinsic_hash, &computed_hash)) {
                span.err("Extrinsic hash mismatch: header={s}, computed={s}", .{
                    std.fmt.fmtSliceHexLower(&header.extrinsic_hash),
                    std.fmt.fmtSliceHexLower(&computed_hash),
                });
                return HeaderValidationError.InvalidExtrinsicHash;
            }
        }

        /// Validate timing constraints
        fn validateTimingConstraints(
            _: *Self,
            state: *const JamState(params),
            header: *const types.Header,
        ) !void {
            const span = trace.span(.validate_timing);
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
        ) !types.BandersnatchPublic {
            _ = self;
            const span = trace.span(.validate_author);
            defer span.deinit();

            // Determine which validator set to use based on epoch transition
            // According to graypaper: use posterior κ' which at epoch boundaries is γ_k
            const time = params.Time().init(state.tau.?, header.slot);
            const validators = if (time.isNewEpoch())
                state.gamma.?.k.validators  // Use gamma.k for first block of new epoch
            else
                state.kappa.?.validators;   // Use kappa for regular blocks

            // Validate author index
            if (header.author_index >= validators.len) {
                span.err("Author index {d} out of bounds (max: {d})", .{
                    header.author_index,
                    validators.len - 1,
                });
                return HeaderValidationError.InvalidAuthorIndex;
            }

            return validators[header.author_index].bandersnatch;
        }

        /// Validate marker timing based on state
        fn validateMarkerTiming(
            self: *Self,
            state: *const JamState(params),
            header: *const types.Header,
        ) !void {
            _ = self;
            const span = trace.span(.validate_marker_timing);
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
            if (transition_time.didCrossTicketSubmissionEnd()) {
                // Tickets marker validation would go here if needed
            } else if (header.tickets_mark != null) {
                span.err("Tickets marker present but we did not cross didCrossTicketSubmissionEnd", .{});
                return HeaderValidationError.InvalidTicketsMarkerTiming;
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
            const span = trace.span(.resolve_tickets);
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
                    // Else we have settled
                } else if (state.gamma.?.s == .tickets)
                    state.gamma.?.s.tickets
                else
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
        ) types.Entropy {
            _ = self;
            const time = params.Time().init(state.tau.?, header.slot);
            const entropy_buffer = state.eta.?;

            if (time.isNewEpoch()) {
                // Use entropy from 3 epochs ago
                return entropy_buffer[2];
            } else {
                // Use current epoch's entropy
                return entropy_buffer[3];
            }
        }

        /// Unified seal validation
        fn validateSeal(self: *Self, ctx: SealContext) !void {
            const span = trace.span(.validate_seal);
            defer span.deinit();

            // Serialize unsigned header
            const unsigned_header = types.HeaderUnsigned.fromHeaderShared(ctx.header);
            const unsigned_header_bytes = try codec.serializeAlloc(
                types.HeaderUnsigned,
                params,
                self.allocator,
                unsigned_header,
            );
            defer self.allocator.free(unsigned_header_bytes);

            // Extract seal signature
            const seal_signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(ctx.header.seal);

            // Build context buffer
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

            const context_bytes = context_buf[0..context_len];

            // Verify signature
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
            const span = trace.span(.validate_entropy_source);
            defer span.deinit();

            // Parse seal signature to get VRF output
            const seal_signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.seal);
            const seal_output_hash = seal_signature.outputHash() catch {
                span.err("Failed to extract seal output hash", .{});
                return HeaderValidationError.InvalidEntropySource;
            };

            // Build context: ENTROPY_CONTEXT ⌢ Y(Hs)
            var context_buf: [MAX_CONTEXT_BUFFER_SIZE]u8 = undefined;
            var context_len: usize = 0;

            @memcpy(context_buf[context_len .. context_len + ENTROPY_CONTEXT.len], ENTROPY_CONTEXT);
            context_len += ENTROPY_CONTEXT.len;

            @memcpy(context_buf[context_len .. context_len + 32], &seal_output_hash);
            context_len += 32;

            const context_bytes = context_buf[0..context_len];

            // Verify entropy source signature
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

            span.debug("Entropy source verification successful", .{});
        }
    };
}
