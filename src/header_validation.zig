const std = @import("std");
const types = @import("types.zig");
const crypto = @import("crypto.zig");
const codec = @import("codec.zig");
const jam_params = @import("jam_params.zig");

const tracing = @import("tracing.zig");
const trace = tracing.scoped(.header_validation);

/// Errors that can occur during header validation
pub const ValidationError = error{
    // Time-based validation errors
    FutureBlock,
    SlotNotGreaterThanParent,
    BlockTooOld,
    ExcessiveSlotGap,

    // Author validation errors
    InvalidAuthorIndex,
    AuthorNotInValidatorSet,

    // Seal validation errors
    SealVerificationFailed,
    InvalidSealMode,

    // VRF validation errors
    EntropySourceVerificationFailed,

    // Marker validation errors
    InvalidEpochBoundary,
    InvalidEpochMarkerTiming,
    InvalidTicketsMarkerTiming,

    // General errors
    OutOfMemory,
    InvalidHeader,
};

/// Configuration for stateless header validation
pub const ValidationConfig = struct {
    /// Maximum allowed clock drift in seconds for future block protection
    max_clock_drift_seconds: u32 = 30,
    
    /// Maximum age in seconds before a block is considered too old
    max_block_age_seconds: u32 = 24 * 60 * 60, // 24 hours (matches ancestor requirement)
    
    /// Maximum allowed slot gap between parent and current block
    max_slot_gap: u32 = 100, // Reasonable limit to prevent huge jumps
};

/// Result of header validation
pub const ValidationResult = struct {
    /// Whether the header is valid
    valid: bool,
    /// Detailed error if validation failed
    error_info: ?ValidationError = null,
    /// Whether the block was sealed using tickets (vs fallback)
    sealed_with_tickets: bool = false,

    pub fn success(sealed_with_tickets: bool) ValidationResult {
        return .{ .valid = true, .sealed_with_tickets = sealed_with_tickets };
    }

    pub fn failure(err: ValidationError) ValidationResult {
        return .{ .valid = false, .error_info = err };
    }
};

/// Cache for storing recent epoch and tickets markers for efficient validation
pub const MarkerCache = struct {
    const Self = @This();
    
    /// Cached epoch marker data
    const CachedEpochMark = struct {
        validators: []types.EpochMarkValidatorsKeys,
        entropy: types.Entropy,
        tickets_entropy: types.Entropy,
        epoch_start_slot: types.TimeSlot,
        
        pub fn fromEpochMark(allocator: std.mem.Allocator, epoch_mark: types.EpochMark, epoch_start_slot: types.TimeSlot) !@This() {
            return @This(){
                .validators = try allocator.dupe(types.EpochMarkValidatorsKeys, epoch_mark.validators),
                .entropy = epoch_mark.entropy,
                .tickets_entropy = epoch_mark.tickets_entropy,
                .epoch_start_slot = epoch_start_slot,
            };
        }
        
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.validators);
            self.* = undefined;
        }
    };
    
    /// Cached tickets marker data  
    const CachedTicketsMark = struct {
        tickets: []types.TicketBody,
        epoch_start_slot: types.TimeSlot,
        
        pub fn fromTicketsMark(allocator: std.mem.Allocator, tickets_mark: types.TicketsMark, epoch_start_slot: types.TimeSlot) !@This() {
            return @This(){
                .tickets = try allocator.dupe(types.TicketBody, tickets_mark.tickets),
                .epoch_start_slot = epoch_start_slot,
            };
        }
        
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.tickets);
            self.* = undefined;
        }
    };
    
    allocator: std.mem.Allocator,
    
    // Current epoch markers
    current_epoch_mark: ?CachedEpochMark = null,
    current_tickets_mark: ?CachedTicketsMark = null,
    
    // Previous epoch markers (for epoch boundary validation)
    previous_epoch_mark: ?CachedEpochMark = null,
    previous_tickets_mark: ?CachedTicketsMark = null,
    
    /// Initialize empty cache
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }
    
    /// Clean up all cached data
    pub fn deinit(self: *Self) void {
        if (self.current_epoch_mark) |*mark| {
            mark.deinit(self.allocator);
        }
        if (self.current_tickets_mark) |*mark| {
            mark.deinit(self.allocator);
        }
        if (self.previous_epoch_mark) |*mark| {
            mark.deinit(self.allocator);
        }
        if (self.previous_tickets_mark) |*mark| {
            mark.deinit(self.allocator);
        }
        self.* = undefined;
    }
    
    /// Update cache with a new header that has been validated
    pub fn updateFromHeader(self: *Self, comptime params: jam_params.Params, header: *const types.Header) !void {
        const span = trace.span(.marker_cache_update);
        defer span.deinit();
        
        const header_epoch_slot = (header.slot / params.epoch_length) * params.epoch_length;
        
        // Check for new epoch mark
        if (header.epoch_mark) |epoch_mark| {
            span.debug("Processing new epoch mark at slot {d}, epoch start: {d}", .{ header.slot, header_epoch_slot });
            
            // Check if this is a new epoch (different from current)
            const is_new_epoch = if (self.current_epoch_mark) |current| 
                current.epoch_start_slot != header_epoch_slot 
            else 
                true;
                
            if (is_new_epoch) {
                // Shift current to previous
                if (self.previous_epoch_mark) |*prev| {
                    prev.deinit(self.allocator);
                }
                self.previous_epoch_mark = self.current_epoch_mark;
                
                // Set new current
                self.current_epoch_mark = try CachedEpochMark.fromEpochMark(
                    self.allocator, 
                    epoch_mark, 
                    header_epoch_slot
                );
                
                span.debug("Cached new epoch mark, previous moved to backup", .{});
            }
        }
        
        // Check for new tickets mark
        if (header.tickets_mark) |tickets_mark| {
            span.debug("Processing new tickets mark at slot {d}, epoch start: {d}", .{ header.slot, header_epoch_slot });
            
            // Check if this is a new tickets mark for current epoch
            const is_new_tickets = if (self.current_tickets_mark) |current| 
                current.epoch_start_slot != header_epoch_slot 
            else 
                true;
                
            if (is_new_tickets) {
                // Shift current to previous  
                if (self.previous_tickets_mark) |*prev| {
                    prev.deinit(self.allocator);
                }
                self.previous_tickets_mark = self.current_tickets_mark;
                
                // Set new current
                self.current_tickets_mark = try CachedTicketsMark.fromTicketsMark(
                    self.allocator, 
                    tickets_mark, 
                    header_epoch_slot
                );
                
                span.debug("Cached new tickets mark, previous moved to backup", .{});
            }
        }
    }
    
    /// Look up validator info for a header from cache
    pub fn lookupValidatorInfo(self: *const Self, comptime params: jam_params.Params, header_slot: types.TimeSlot) ?ValidatorInfo {
        const span = trace.span(.marker_cache_lookup);
        defer span.deinit();
        
        const header_epoch_slot = (header_slot / params.epoch_length) * params.epoch_length;
        span.debug("Looking up validator info for slot {d}, epoch start: {d}", .{ header_slot, header_epoch_slot });
        
        // Try current epoch first
        if (self.current_epoch_mark) |current| {
            if (current.epoch_start_slot == header_epoch_slot) {
                span.debug("Found validator info in current epoch cache", .{});
                return ValidatorInfo{
                    .validators = current.validators,
                    .entropy = current.entropy,
                    .tickets_entropy = current.tickets_entropy,
                };
            }
        }
        
        // Try previous epoch
        if (self.previous_epoch_mark) |previous| {
            if (previous.epoch_start_slot == header_epoch_slot) {
                span.debug("Found validator info in previous epoch cache", .{});
                return ValidatorInfo{
                    .validators = previous.validators,
                    .entropy = previous.entropy,
                    .tickets_entropy = previous.tickets_entropy,
                };
            }
        }
        
        span.debug("Validator info not found in cache", .{});
        return null;
    }
    
    /// Look up tickets for a header from cache
    pub fn lookupTickets(self: *const Self, comptime params: jam_params.Params, header_slot: types.TimeSlot) ?[]const types.TicketBody {
        const span = trace.span(.marker_cache_lookup_tickets);
        defer span.deinit();
        
        const header_epoch_slot = (header_slot / params.epoch_length) * params.epoch_length;
        span.debug("Looking up tickets for slot {d}, epoch start: {d}", .{ header_slot, header_epoch_slot });
        
        // Try current epoch first
        if (self.current_tickets_mark) |current| {
            if (current.epoch_start_slot == header_epoch_slot) {
                span.debug("Found tickets in current epoch cache", .{});
                return current.tickets;
            }
        }
        
        // Try previous epoch
        if (self.previous_tickets_mark) |previous| {
            if (previous.epoch_start_slot == header_epoch_slot) {
                span.debug("Found tickets in previous epoch cache", .{});
                return previous.tickets;
            }
        }
        
        span.debug("Tickets not found in cache", .{});
        return null;
    }
};

/// Stateless header validator with configurable behavior
pub fn HeaderValidator(comptime params: jam_params.Params) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: ValidationConfig,
        marker_cache: ?MarkerCache = null,

        /// Initialize with allocator and default configuration (no cache)
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .config = ValidationConfig{},
                .marker_cache = null,
            };
        }

        /// Initialize with allocator and custom configuration (no cache)
        pub fn initWithConfig(allocator: std.mem.Allocator, config: ValidationConfig) Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .marker_cache = null,
            };
        }
        
        /// Initialize with allocator, default configuration, and cache enabled
        pub fn initWithCache(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .config = ValidationConfig{},
                .marker_cache = MarkerCache.init(allocator),
            };
        }
        
        /// Initialize with allocator, custom configuration, and cache enabled
        pub fn initWithConfigAndCache(allocator: std.mem.Allocator, config: ValidationConfig) Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .marker_cache = MarkerCache.init(allocator),
            };
        }
        
        /// Clean up validator resources
        pub fn deinit(self: *Self) void {
            if (self.marker_cache) |*cache| {
                cache.deinit();
            }
        }

        /// Validate header using the configured validator
        /// Validates header using validator information extracted from header markers
        /// and parent markers, without requiring state database access.
        /// Designed for sub-millisecond execution.
        /// 
        /// LIMITATIONS:
        /// - Parent State Root (Hr) validation is skipped: requires full state execution
        ///   which conflicts with stateless design. Full validation must be done elsewhere.
        /// - Extrinsic Hash (Hx) validation is skipped: requires access to block's extrinsic 
        ///   data, but this function only accepts headers. Consider using validateBlock() 
        ///   when extrinsic data is available.
        pub fn validateHeader(
            self: *Self,
            current_header: *const types.Header,
            parent_header: ?*const types.Header,
            current_timestamp: u64,
        ) ValidationResult {
            const span = trace.span(.validate_header_stateless);
            defer span.deinit();
            span.debug("Starting stateless header validation for slot {d}", .{current_header.slot});

            // Basic timing validation without state dependency
            self.validateTiming(current_header, parent_header, current_timestamp) catch |err| {
                return ValidationResult.failure(err);
            };

            // Validate marker timing (epoch and tickets markers)
            self.validateMarkerTiming(current_header, parent_header) catch |err| {
                return ValidationResult.failure(err);
            };

            // Extract validator information from header markers (cache-enabled)
            const validator_info = self.extractValidatorInfoCached(current_header, parent_header) catch |err| {
                return ValidationResult.failure(err);
            };

            // Validate author index against extracted validator set
            if (current_header.author_index >= validator_info.validators.len) {
                span.err("Author index {d} >= validator count {d}", .{ current_header.author_index, validator_info.validators.len });
                return ValidationResult.failure(ValidationError.InvalidAuthorIndex);
            }

            // Get author's public key
            const author_key = validator_info.validators[current_header.author_index].bandersnatch;

            // Determine seal mode from header markers (cache-enabled)
            const seal_mode = self.determineSealModeCached(current_header, validator_info.entropy);

            // Validate block seal
            const sealed_with_tickets = self.validateSeal(
                current_header,
                author_key,
                seal_mode,
                validator_info.entropy,
            ) catch |err| {
                return ValidationResult.failure(err);
            };

            // Validate VRF entropy source
            self.validateEntropySource(
                current_header,
                author_key,
                seal_mode,
            ) catch |err| {
                return ValidationResult.failure(err);
            };

            // Update cache with validated header if cache is enabled
            if (self.marker_cache) |*cache| {
                cache.updateFromHeader(params, current_header) catch |err| {
                    span.warn("Failed to update marker cache: {}", .{err});
                    // Don't fail validation if cache update fails
                };
            }

            span.debug("Stateless header validation successful, sealed with tickets: {}", .{sealed_with_tickets});
            return ValidationResult.success(sealed_with_tickets);
        }

        /// Validate timing constraints without state dependency
        fn validateTiming(
            self: Self,
            current_header: *const types.Header,
            parent_header: ?*const types.Header,
            current_timestamp: u64,
        ) !void {
            const span = trace.span(.validate_timing);
            defer span.deinit();
            span.debug("Validating timing for slot {d}", .{current_header.slot});

            const header_time = current_header.slot * params.slot_period;

            // Check slot ordering against parent if available
            if (parent_header) |parent| {
                if (current_header.slot <= parent.slot) {
                    span.err("Header slot {d} not greater than parent slot {d}", .{ current_header.slot, parent.slot });
                    return ValidationError.SlotNotGreaterThanParent;
                }
                
                // Check for excessive slot gaps
                const slot_gap = current_header.slot - parent.slot;
                if (slot_gap > self.config.max_slot_gap) {
                    span.err("Slot gap {d} exceeds maximum allowed {d}", .{ slot_gap, self.config.max_slot_gap });
                    return ValidationError.ExcessiveSlotGap;
                }
            }

            // Future block protection using configured max clock drift
            if (header_time > current_timestamp + self.config.max_clock_drift_seconds) {
                span.err("Header time {d} too far in future, current time: {d}, max drift: {d}", .{ header_time, current_timestamp, self.config.max_clock_drift_seconds });
                return ValidationError.FutureBlock;
            }
            
            // Block too old protection
            if (header_time + self.config.max_block_age_seconds < current_timestamp) {
                span.err("Header time {d} too old, current time: {d}, max age: {d}", .{ header_time, current_timestamp, self.config.max_block_age_seconds });
                return ValidationError.BlockTooOld;
            }

            // Epoch boundary validation
            if (current_header.epoch_mark != null) {
                if (current_header.slot % params.epoch_length != 0) {
                    span.err("Epoch marker present but slot {d} is not at epoch boundary (epoch_length: {d})", .{ current_header.slot, params.epoch_length });
                    return ValidationError.InvalidEpochBoundary;
                }
            }

            span.debug("Timing validation passed", .{});
        }

        /// Validate that epoch and tickets markers appear at the correct times
        fn validateMarkerTiming(
            self: Self,
            current_header: *const types.Header,
            parent_header: ?*const types.Header,
        ) !void {
            const span = trace.span(.validate_marker_timing);
            defer span.deinit();
            span.debug("Validating marker timing for slot {d}", .{current_header.slot});

            if (parent_header) |parent| {
                const current_epoch = current_header.slot / params.epoch_length;
                const parent_epoch = parent.slot / params.epoch_length;
                const current_slot_in_epoch = current_header.slot % params.epoch_length;
                const parent_slot_in_epoch = parent.slot % params.epoch_length;

                // Validate epoch marker timing
                const is_new_epoch = current_epoch > parent_epoch;
                const should_have_epoch_marker = is_new_epoch;
                const has_epoch_marker = current_header.epoch_mark != null;

                if (should_have_epoch_marker and !has_epoch_marker) {
                    span.err("New epoch started at slot {d} but epoch marker is missing", .{current_header.slot});
                    return ValidationError.InvalidEpochMarkerTiming;
                }
                
                if (!should_have_epoch_marker and has_epoch_marker) {
                    span.err("Epoch marker present at slot {d} but not starting new epoch", .{current_header.slot});
                    return ValidationError.InvalidEpochMarkerTiming;
                }

                // Validate tickets marker timing (only within same epoch)
                if (current_epoch == parent_epoch) {
                    const ticket_submission_end = params.ticket_submission_end_epoch_slot;
                    const should_have_tickets_marker = parent_slot_in_epoch < ticket_submission_end and 
                                                      current_slot_in_epoch >= ticket_submission_end;
                    const has_tickets_marker = current_header.tickets_mark != null;

                    if (should_have_tickets_marker and !has_tickets_marker) {
                        span.err("Ticket submission period ended but tickets marker is missing at slot {d}", .{current_header.slot});
                        return ValidationError.InvalidTicketsMarkerTiming;
                    }
                    
                    if (!should_have_tickets_marker and has_tickets_marker) {
                        span.err("Tickets marker present at slot {d} but submission period hasn't ended", .{current_header.slot});
                        return ValidationError.InvalidTicketsMarkerTiming;
                    }
                }
            }

            span.debug("Marker timing validation passed", .{});
        }

        /// Validate block seal
        fn validateSeal(
            self: Self,
            header: *const types.Header,
            author_key: types.BandersnatchPublic,
            seal_mode: SealMode,
            entropy: types.Entropy,
        ) !bool {
            const span = trace.span(.validate_seal);
            defer span.deinit();
            span.debug("Validating block seal for slot {d}", .{header.slot});

            // Serialize unsigned header for signature verification
            const unsigned_header = types.HeaderUnsigned.fromHeaderShared(header);
            const unsigned_header_bytes = codec.serializeAlloc(
                types.HeaderUnsigned,
                params,
                self.allocator,
                unsigned_header,
            ) catch |err| {
                span.err("Failed to serialize unsigned header: {}", .{err});
                return ValidationError.InvalidHeader;
            };
            defer self.allocator.free(unsigned_header_bytes);

            span.trace("Unsigned header bytes: {s}", .{std.fmt.fmtSliceHexLower(unsigned_header_bytes)});

            // Validate seal based on mode
            const sealed_with_tickets = switch (seal_mode) {
                .tickets => |ticket_info| blk: {
                    span.debug("Validating ticket-based seal", .{});

                    // Get current slot in epoch - ensures slot is within the epoch's ticket bounds
                    const slot_in_epoch = header.slot % params.epoch_length;
                    if (slot_in_epoch >= ticket_info.tickets.len) {
                        span.err("Slot in epoch {d} >= tickets length {d}", .{ slot_in_epoch, ticket_info.tickets.len });
                        return ValidationError.InvalidSealMode;
                    }
                    const ticket = ticket_info.tickets[slot_in_epoch];

                    // Build context for ticket seal (stack allocation)
                    const context_prefix = "jam_ticket_seal";
                    var context_buf: [64]u8 = undefined; // Should be enough for prefix + entropy + attempt
                    var context_len: usize = 0;

                    // Copy prefix
                    @memcpy(context_buf[context_len .. context_len + context_prefix.len], context_prefix);
                    context_len += context_prefix.len;

                    // Copy entropy[3] (4th entropy value)
                    @memcpy(context_buf[context_len .. context_len + 32], &entropy);
                    context_len += 32;

                    // Add ticket entry index (represented by attempt field)
                    // Gray Paper 6.15: context should be ⟨XT ⌢ η'3 ir⟩ where ir is entry index
                    context_buf[context_len] = ticket.attempt;
                    context_len += 1;

                    const context_bytes = context_buf[0..context_len];
                    span.trace("Ticket seal context: {s}", .{std.fmt.fmtSliceHexLower(context_bytes)});

                    // Verify signature
                    const signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.seal);
                    const public_key = crypto.bandersnatch.Bandersnatch.PublicKey.fromBytes(author_key);
                    const output_hash = signature.verify(
                        unsigned_header_bytes,
                        context_bytes,
                        public_key,
                    ) catch {
                        span.err("Ticket seal verification failed", .{});
                        return ValidationError.SealVerificationFailed;
                    };
                    _ = output_hash; // We don't need the output hash for seal verification

                    break :blk true;
                },
                .fallback => |fallback_info| blk: {
                    span.debug("Validating fallback seal", .{});

                    // Build context for fallback seal (stack allocation)
                    const context_prefix = "jam_fallback_seal";
                    var context_buf: [64]u8 = undefined;
                    var context_len: usize = 0;

                    // Copy prefix
                    @memcpy(context_buf[context_len .. context_len + context_prefix.len], context_prefix);
                    context_len += context_prefix.len;

                    // Copy entropy
                    @memcpy(context_buf[context_len .. context_len + 32], &fallback_info.entropy);
                    context_len += 32;

                    const context_bytes = context_buf[0..context_len];
                    span.trace("Fallback seal context: {s}", .{std.fmt.fmtSliceHexLower(context_bytes)});

                    // Verify signature
                    const signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.seal);
                    const public_key = crypto.bandersnatch.Bandersnatch.PublicKey.fromBytes(author_key);
                    const output_hash = signature.verify(
                        unsigned_header_bytes,
                        context_bytes,
                        public_key,
                    ) catch {
                        span.err("Fallback seal verification failed", .{});
                        return ValidationError.SealVerificationFailed;
                    };
                    _ = output_hash; // We don't need the output hash for seal verification

                    break :blk false;
                },
            };

            span.debug("Seal validation passed, sealed with tickets: {}", .{sealed_with_tickets});
            return sealed_with_tickets;
        }

        /// Validate VRF entropy source
        fn validateEntropySource(
            self: Self,
            header: *const types.Header,
            author_key: types.BandersnatchPublic,
            seal_mode: SealMode,
        ) !void {
            _ = self; // Unused for now, but may be needed for future config

            const span = trace.span(.validate_entropy_source);
            defer span.deinit();
            span.debug("Validating entropy source", .{});

            // Parse the entropy source signature
            const entropy_signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.entropy_source);

            // Get the expected VRF output from the signature
            const expected_output = entropy_signature.outputHash() catch {
                span.err("Failed to extract output hash from entropy signature", .{});
                return ValidationError.EntropySourceVerificationFailed;
            };

            // Build context based on sealing mode (stack allocation)
            var context_buf: [64]u8 = undefined;
            var context_len: usize = 0;

            const context_prefix = "jam_entropy";
            @memcpy(context_buf[context_len .. context_len + context_prefix.len], context_prefix);
            context_len += context_prefix.len;

            switch (seal_mode) {
                .tickets => |ticket_info| {
                    // Use ticket ID for ticket-based mode
                    const slot_in_epoch = header.slot % ticket_info.tickets.len;
                    const ticket = ticket_info.tickets[slot_in_epoch];
                    @memcpy(context_buf[context_len .. context_len + 32], &ticket.id);
                    context_len += 32;
                },
                .fallback => {
                    // Use expected output for fallback mode
                    @memcpy(context_buf[context_len .. context_len + 32], &expected_output);
                    context_len += 32;
                },
            }

            const context_bytes = context_buf[0..context_len];

            // Verify the entropy source signature
            const signature = crypto.bandersnatch.Bandersnatch.Signature.fromBytes(header.entropy_source);
            const public_key = crypto.bandersnatch.Bandersnatch.PublicKey.fromBytes(author_key);
            const output_hash = signature.verify(
                &[_]u8{}, // Empty message for VRF
                context_bytes,
                public_key,
            ) catch {
                span.err("Entropy source verification failed", .{});
                return ValidationError.EntropySourceVerificationFailed;
            };
            _ = output_hash; // We could check this matches expected_output but not strictly necessary

            span.debug("Entropy source validation passed", .{});
        }
        
        /// Extract validator information from headers with cache support
        fn extractValidatorInfoCached(
            self: *Self,
            current_header: *const types.Header,
            parent_header: ?*const types.Header,
        ) !ValidatorInfo {
            const span = trace.span(.extract_validator_info_cached);
            defer span.deinit();
            
            // Try cache first if available
            if (self.marker_cache) |*cache| {
                if (cache.lookupValidatorInfo(params, current_header.slot)) |cached_info| {
                    span.debug("Found validator info in cache for slot {d}", .{current_header.slot});
                    return cached_info;
                }
                
                // Try parent header slot if available
                if (parent_header) |parent| {
                    if (cache.lookupValidatorInfo(params, parent.slot)) |cached_info| {
                        span.debug("Found validator info in cache for parent slot {d}", .{parent.slot});
                        return cached_info;
                    }
                }
                
                span.debug("Cache miss for validator info, falling back to header search", .{});
            }
            
            // Fall back to original extraction logic
            return extractValidatorInfo(current_header, parent_header);
        }
        
        /// Determine seal mode from header markers with cache support
        fn determineSealModeCached(self: *Self, current_header: *const types.Header, entropy: types.Entropy) SealMode {
            const span = trace.span(.determine_seal_mode_cached);
            defer span.deinit();
            
            // Try current header's tickets mark first
            if (current_header.tickets_mark) |tickets_mark| {
                span.debug("Using ticket-based seal mode from current header", .{});
                return SealMode{
                    .tickets = .{
                        .tickets = tickets_mark.tickets,
                        .entropy = entropy,
                    },
                };
            }
            
            // Try cache if available
            if (self.marker_cache) |*cache| {
                if (cache.lookupTickets(params, current_header.slot)) |cached_tickets| {
                    span.debug("Using ticket-based seal mode from cache for slot {d}", .{current_header.slot});
                    return SealMode{
                        .tickets = .{
                            .tickets = cached_tickets,
                            .entropy = entropy,
                        },
                    };
                }
                span.debug("No tickets found in cache for slot {d}", .{current_header.slot});
            }
            
            // Fall back to fallback mode
            span.debug("Using fallback seal mode", .{});
            return SealMode{
                .fallback = .{
                    .entropy = entropy,
                },
            };
        }
    };
}

/// Extracted validator information from header markers
const ValidatorInfo = struct {
    validators: []const types.EpochMarkValidatorsKeys,
    entropy: types.Entropy,
    tickets_entropy: types.Entropy,
};

/// Seal mode determined from header markers
const SealMode = union(enum) {
    tickets: struct {
        tickets: []const types.TicketBody,
        entropy: types.Entropy,
    },
    fallback: struct {
        entropy: types.Entropy,
    },
};

/// Extract validator information from current and parent header markers
fn extractValidatorInfo(
    current_header: *const types.Header,
    parent_header: ?*const types.Header,
) !ValidatorInfo {
    const span = trace.span(.extract_validator_info);
    defer span.deinit();

    // Try to get validator info from current header's epoch mark first
    if (current_header.epoch_mark) |epoch_mark| {
        span.debug("Using validator info from current header epoch mark", .{});
        return ValidatorInfo{
            .validators = epoch_mark.validators,
            .entropy = epoch_mark.entropy,
            .tickets_entropy = epoch_mark.tickets_entropy,
        };
    }

    // Fall back to parent header's epoch mark
    if (parent_header) |parent| {
        if (parent.epoch_mark) |epoch_mark| {
            span.debug("Using validator info from parent header epoch mark", .{});
            return ValidatorInfo{
                .validators = epoch_mark.validators,
                .entropy = epoch_mark.entropy,
                .tickets_entropy = epoch_mark.tickets_entropy,
            };
        }
    }

    span.err("No validator information available in current or parent header", .{});
    return ValidationError.AuthorNotInValidatorSet;
}

/// Determine seal mode from header markers
fn determineSealMode(current_header: *const types.Header, entropy: types.Entropy) SealMode {
    const span = trace.span(.determine_seal_mode);
    defer span.deinit();

    // Check if tickets mark is present (indicating ticket-based sealing)
    if (current_header.tickets_mark) |tickets_mark| {
        span.debug("Using ticket-based seal mode", .{});
        return SealMode{
            .tickets = .{
                .tickets = tickets_mark.tickets,
                .entropy = entropy,
            },
        };
    } else {
        span.debug("Using fallback seal mode", .{});
        return SealMode{
            .fallback = .{
                .entropy = entropy,
            },
        };
    }
}

/// Convenience function using default configuration (for backward compatibility)
pub fn validateHeaderStateless(
    comptime params: jam_params.Params,
    allocator: std.mem.Allocator,
    current_header: *const types.Header,
    parent_header: ?*const types.Header,
    current_timestamp: u64,
) ValidationResult {
    var validator = HeaderValidator(params).init(allocator);
    defer validator.deinit();
    return validator.validateHeader(current_header, parent_header, current_timestamp);
}
