const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const codec = @import("../codec.zig");

const pvm = @import("../pvm.zig");
const pvm_invocation = @import("../pvm/invocation.zig");

const Params = @import("../jam_params.zig").Params;

// Add tracing import
const trace = @import("../tracing.zig").scoped(.accumulate);

const AccumulateArgs = struct {
    timeslot: types.TimeSlot,
    service_id: types.ServiceId,
    operands: []const AccumulationOperand,
};

/// Accumulation Invocation
pub fn invoke(
    comptime params: Params,
    allocator: std.mem.Allocator,
    context: AccumulationContext(params),
    tau: types.TimeSlot,
    entropy: types.Entropy, // n0
    service_id: types.ServiceId,
    gas_limit: types.Gas,
    accumulation_operands: []const AccumulationOperand,
) !AccumulationResult(params) {
    const span = trace.span(.invoke);
    defer span.deinit();
    span.debug("Starting accumulation invocation for service {d}", .{service_id});
    span.debug("Time slot: {d}, Gas limit: {d}, Operand count: {d}", .{ tau, gas_limit, accumulation_operands.len });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&entropy)});

    // Look up the service account
    const service_account = context.service_accounts.getAccount(service_id) orelse {
        span.err("Service {d} not found", .{service_id});
        return error.ServiceNotFound;
    };

    span.debug("Found service account for ID {d}", .{service_id});

    // Prepare accumulation arguments
    span.debug("Preparing accumulation arguments", .{});
    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    const arguments = AccumulateArgs{
        .timeslot = tau,
        .service_id = service_id,
        .operands = accumulation_operands,
    };

    try codec.serialize(AccumulateArgs, .{}, args_buffer.writer(), arguments);

    // FIXME: make this map at compile time
    span.debug("Setting up host call functions", .{});
    // Set up host call functions
    var host_call_map = std.AutoHashMapUnmanaged(u32, pvm.PVM.HostCallFn){};
    // errdefer host_call_map.deinit(allocator); // host_call_map will be owned by ExecutionContext

    const host_calls = AccumulateHostCalls(params);

    // Register host calls
    span.debug("Registering host call functions", .{});
    try host_call_map.put(allocator, @intFromEnum(HostCallId.gas), host_calls.gasRemaining);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.lookup), host_calls.lookupPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.read), host_calls.readStorage);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.write), host_calls.writeStorage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.info), host_calls.getServiceInfo);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.bless), host_calls.blessService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.assign), host_calls.callAssignCore);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.designate), host_calls.designateValidators);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.checkpoint), host_calls.checkpoint);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.new), host_calls.newService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.upgrade), host_calls.upgradeService);
    try host_call_map.put(allocator, @intFromEnum(HostCallId.transfer), host_calls.transfer);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.eject), host_calls.ejectService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.query), host_calls.queryPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.solicit), host_calls.solicitPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.forget), host_calls.forgetPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.yield), host_calls.yieldAccumulateResult);

    // Initialize host call context B.6
    span.debug("Initializing host call context", .{});
    var host_call_context = AccumulateHostCalls(params).Context{
        .allocator = allocator,
        .service_id = service_id,
        .context = context,
        .new_service_id = generateServiceId(context.service_accounts, service_id, entropy, tau),
        .deferred_transfers = std.ArrayList(DeferredTransfer).init(allocator),
        .accumulation_output = null,
    };
    defer host_call_context.deinit();
    span.debug("Generated new service ID: {d}", .{host_call_context.new_service_id});

    // Execute the PVM invocation
    const code = service_account.getPreimage(service_account.code_hash) orelse {
        span.err("Service code not available for hash: {s}", .{std.fmt.fmtSliceHexLower(&service_account.code_hash)});
        return error.ServiceCodeNotAvailable;
    };
    span.debug("Retrieved service code, length: {d} bytes", .{code.len});

    span.debug("Starting PVM machine invocation", .{});
    const pvm_span = span.child(.pvm_invocation);
    defer pvm_span.deinit();

    const result = try pvm_invocation.machineInvocation(
        allocator,
        code,
        5, // Accumulation entry point index per section 9.1
        @intCast(gas_limit),
        args_buffer.items,
        host_call_map,
        @ptrCast(&host_call_context),
    );

    pvm_span.debug("PVM invocation completed: {s}", .{@tagName(result)});

    // Calculate gas used
    const gas_used = 10; // FIXME: add gas calc here
    span.debug("Gas used for invocation: {d}", .{gas_used});

    // Build the result array of deferred transfers
    const transfers = try host_call_context.deferred_transfers.toOwnedSlice();
    span.debug("Number of deferred transfers created: {d}", .{transfers.len});

    for (transfers, 0..) |transfer, i| {
        span.debug("Transfer {d}: {d} -> {d}, amount: {d}", .{
            i, transfer.sender, transfer.destination, transfer.amount,
        });
    }

    if (host_call_context.accumulation_output) |output| {
        span.debug("Accumulation output present: {s}", .{std.fmt.fmtSliceHexLower(&output)});
    } else {
        span.debug("No accumulation output produced", .{});
    }

    span.debug("Accumulation invocation completed successfully", .{});
    return AccumulationResult(params){
        .state_context = context,
        .transfers = transfers,
        .accumulation_output = host_call_context.accumulation_output,
        .gas_used = gas_used,
    };
}

// 12.13 State components needed for Accumulation
pub fn AccumulationContext(params: Params) type {
    return struct {
        service_accounts: *state.Delta, // d ∈ D⟨N_S → A⟩
        validator_keys: *state.Iota, // i ∈ ⟦K⟧_V
        authorizer_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items), // q ∈ _C⟦H⟧^Q_H_C
        privileges: *state.Chi, // x ∈ (N_S, N_S, N_S, D⟨N_S → N_G⟩)

        pub fn buildFromState(jam_state: state.JamState(params)) @This() {
            return @This(){
                .service_accounts = &jam_state.delta.?,
                .validator_keys = &jam_state.iota.?,
                .authorizer_queue = &jam_state.phi.?,
                .privileges = &jam_state.chi.?,
            };
        }
    };
}

/// 12.18 AccumulationOperand represents a wrangled tuple of operands used by the PVM Accumulation function.
/// It contains the rephrased work items for a specific service within work reports.
pub const AccumulationOperand = struct {
    pub const Output = union(enum) {
        /// Successful execution output as an octet sequence
        success: []const u8,
        /// Error code if execution failed
        err: WorkExecutionError,
    };

    /// The output or error of the work item execution.
    /// Can be either an octet sequence (Y) or an error (J).
    output: Output,

    /// The hash of the payload within the work item
    /// that was executed in the refine stage
    payload_hash: [32]u8,

    /// The hash of the work package
    work_package_hash: [32]u8,

    /// The authorization output blob for the work item
    authorization_output: []const u8,

    pub fn fromWorkReport(allocator: std.mem.Allocator, report: types.WorkReport) ![]AccumulationOperand {
        // Ensure there are results in the report
        if (report.results.len == 0) {
            return error.NoResults;
        }

        // Allocate an array of AccumulationOperand with the same length as report.results
        var operands = try allocator.alloc(AccumulationOperand, report.results.len);
        errdefer {
            // Clean up any already initialized operands
            for (operands) |*operand| {
                operand.deinit(allocator);
            }
            allocator.free(operands);
        }

        // Create an AccumulationOperand for each result in the report
        for (report.results, 0..) |result, i| {
            // Map output type from WorkExecResult to AccumulationOperand.output
            const output: Output = switch (result.result) {
                .ok => |data| .{
                    .success = try allocator.dupe(u8, data),
                },
                .out_of_gas => .{
                    .err = .OutOfGas,
                },
                .panic => .{
                    .err = .ProgramTermination,
                },
                .bad_code => .{
                    .err = .ServiceCodeUnavailable,
                },
                .code_oversize => .{
                    .err = .ServiceCodeTooLarge,
                },
            };

            // Set up the operand
            operands[i] = .{
                .output = output,
                .payload_hash = result.payload_hash,
                .work_package_hash = report.package_spec.hash,
                .authorization_output = try allocator.dupe(u8, report.auth_output),
            };
        }

        return operands;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.output == .success) {
            allocator.free(self.output.success);
        }

        // Free the authorization output
        allocator.free(self.authorization_output);
        self.* = undefined;
    }
};

/// Represents possible error types from work execution
const WorkExecutionError = enum {
    OutOfGas, // ∞
    ProgramTermination, // ☇
    InvalidExportCount, // ⊚
    ServiceCodeUnavailable, // BAD
    ServiceCodeTooLarge, // BIG
};

/// DeferredTransfer represents a transfer request generated during accumulation
/// Based on the graypaper equation 12.14: T ≡ {s ∈ N_S, d ∈ N_S, a ∈ N_B, m ∈ Y_W_T, g ∈ N_G}
pub const DeferredTransfer = struct {
    /// The service index of the sending account
    sender: types.ServiceId,

    /// The service index of the receiving account
    destination: types.ServiceId,

    /// The balance amount to be transferred
    amount: types.Balance,

    /// Memo/message attached to the transfer (fixed length W_T = 128 octets)
    memo: [128]u8,

    /// Gas limit for executing the transfer's on_transfer handler
    gas_limit: types.Gas,
};

/// Return type for the accumulation invoke function,
pub fn AccumulationResult(params: Params) type {
    return struct {
        /// Updated state context after accumulation
        state_context: AccumulationContext(params),

        /// Sequence of deferred transfers resulting from accumulation
        transfers: []DeferredTransfer,

        /// Optional accumulation output hash (null if no output was produced)
        accumulation_output: ?types.AccumulateRoot,

        /// Amount of gas consumed during accumulation
        gas_used: types.Gas,
    };
}

/// Return codes for host call operations
pub const HostCallReturnCode = enum(u64) {
    OK = 0, // The return value indicating general success
    NONE = 0xFFFFFFFFFFFFFFFF, // The return value indicating an item does not exist (2^64 - 1)
    WHAT = 0xFFFFFFFFFFFFFFFE, // Name unknown (2^64 - 2)
    OOB = 0xFFFFFFFFFFFFFFFD, // The inner pvm memory index provided for reading/writing is not accessible (2^64 - 3)
    WHO = 0xFFFFFFFFFFFFFFFC, // Index unknown (2^64 - 4)
    FULL = 0xFFFFFFFFFFFFFFFB, // Storage full (2^64 - 5)
    CORE = 0xFFFFFFFFFFFFFFFA, // Core index unknown (2^64 - 6)
    CASH = 0xFFFFFFFFFFFFFFF9, // Insufficient funds (2^64 - 7)
    LOW = 0xFFFFFFFFFFFFFFF8, // Gas limit too low (2^64 - 8)
    HUH = 0xFFFFFFFFFFFFFFF7, // The item is already solicited or cannot be forgotten (2^64 - 9)
};

/// Checks if a service ID is available and finds the next available one if not
/// As defined in B.13 of the graypaper
fn check(service_accounts: *state.Delta, candidate_id: types.ServiceId) types.ServiceId {
    const span = trace.span(.check_service_id);
    defer span.deinit();
    span.debug("Checking service ID availability: {d}", .{candidate_id});

    // If the ID is not already used, return it
    if (service_accounts.getAccount(candidate_id) == null) {
        span.debug("Service ID {d} is available", .{candidate_id});
        return candidate_id;
    }

    span.debug("Service ID {d} is already used, calculating next ID", .{candidate_id});

    // Otherwise, calculate the next candidate in the sequence
    // The formula is: check((i - 2^8 + 1) mod (2^32 - 2^9) + 2^8)
    const next_id = 0x100 + ((candidate_id - 0x100 + 1) % (std.math.maxInt(u32) - 0x200));
    span.debug("Next candidate ID: {d}", .{next_id});

    // Recursive call to check the next candidate
    return check(service_accounts, next_id);
}

/// Generates a deterministic service ID based on creator service, entropy, and timeslot
/// As defined in B.9 of the graypaper
fn generateServiceId(service_accounts: *state.Delta, creator_id: types.ServiceId, entropy: [32]u8, timeslot: u32) types.ServiceId {
    const span = trace.span(.generate_service_id);
    defer span.deinit();
    span.debug("Generating service ID - creator: {d}, timeslot: {d}", .{ creator_id, timeslot });
    span.trace("Entropy: {s}", .{std.fmt.fmtSliceHexLower(&entropy)});

    // Create input for hash: service ID + entropy + timeslot
    var hash_input: [32 + 4 + 4]u8 = undefined;

    // Copy service ID as bytes (4 bytes in little-endian format)
    std.mem.writeInt(u32, hash_input[0..4], creator_id, .little);

    // Copy entropy (32 bytes)
    std.mem.copyForwards(u8, hash_input[4..36], &entropy);

    // Copy timeslot (4 bytes in little-endian format)
    std.mem.writeInt(u32, hash_input[36..40], timeslot, .little);
    span.trace("Hash input: {s}", .{std.fmt.fmtSliceHexLower(&hash_input)});

    // Hash the input using Blake2b-256
    var hash_output: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(&hash_input, &hash_output, .{});
    span.trace("Hash output: {s}", .{std.fmt.fmtSliceHexLower(&hash_output)});

    // Generate initial ID: take first 4 bytes of hash mod (2^32 - 2^9) + 2^8
    const initial_value = std.mem.readInt(u32, hash_output[0..4], .little);
    const candidate_id = 0x100 + (initial_value % (std.math.maxInt(u32) - 0x200));
    span.debug("Initial candidate ID: {d}", .{candidate_id});

    // Check if this ID is available, and find next available if not
    const final_id = check(service_accounts, candidate_id);
    span.debug("Final service ID: {d}", .{final_id});
    return final_id;
}

/// Enum representing all possible host call operations
pub const HostCallId = enum(u32) {
    gas = 0, // Host call for retrieving remaining gas counter
    lookup = 1, // Host call for looking up preimages by hash
    read = 2, // Host call for reading from service storage
    write = 3, // Host call for writing to service storage
    info = 4, // Host call for obtaining service account information
    bless = 5, // Host call for empowering a service with privileges
    assign = 6, // Host call for assigning cores to validators
    designate = 7, // Host call for designating validator keys for the next epoch
    checkpoint = 8, // Host call for creating a checkpoint of state
    new = 9, // Host call for creating a new service account
    upgrade = 10, // Host call for upgrading service code
    transfer = 11, // Host call for transferring balance between services
    eject = 12, // Host call for ejecting/removing a service
    query = 13, // Host call for querying preimage status
    solicit = 14, // Host call for soliciting a preimage
    forget = 15, // Host call for forgetting/removing a preimage
    yield = 16, // Host call for yielding accumulation trie result
};

pub fn AccumulateHostCalls(params: Params) type {
    return struct {
        /// Context maintained during host call execution
        const Context =
            struct {
            allocator: std.mem.Allocator,
            context: AccumulationContext(params),
            service_id: types.ServiceId,
            new_service_id: types.ServiceId,
            deferred_transfers: std.ArrayList(DeferredTransfer),
            accumulation_output: ?types.AccumulateRoot,

            pub fn deinit(self: *@This()) void {
                self.deferred_transfers.deinit();
                self.* = undefined;
            }
        };

        /// Host call implementation for gas remaining (Ω_G)
        fn gasRemaining(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const span = trace.span(.host_call_gas);
            defer span.deinit();
            span.debug("Host call: gas remaining", .{});

            _ = call_ctx;
            const remaining_gas = exec_ctx.gas - 10;
            exec_ctx.registers[7] = @intCast(remaining_gas);

            span.debug("Remaining gas: {d}", .{remaining_gas});
            return .play;
        }

        /// Host call implementation for lookup preimage (Ω_L)
        fn lookupPreimage(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const span = trace.span(.host_call_lookup);
            defer span.deinit();

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const service_id = exec_ctx.registers[7];
            const hash_ptr = exec_ctx.registers[8];
            const output_ptr = exec_ctx.registers[9];
            const offset = exec_ctx.registers[10];
            const limit = exec_ctx.registers[11];

            span.debug("Host call: lookup preimage. Service: {d}, Hash ptr: 0x{x}, Output ptr: 0x{x}", .{
                service_id, hash_ptr, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });

            // Get service account based on special cases as per graypaper
            const service_account = if (service_id == host_ctx.service_id or service_id == 0xFFFFFFFFFFFFFFFF) blk: {
                span.debug("Using current service ID: {d}", .{host_ctx.service_id});
                break :blk host_ctx.context.service_accounts.getAccount(host_ctx.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk host_ctx.context.service_accounts.getAccount(@intCast(service_id));
            };

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE); // Index unknown
                return .play;
            }

            // Read hash from memory (access verification is implicit)
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash_slice = exec_ctx.memory.readSlice(@truncate(hash_ptr), 32) catch {
                // Error: memory access failed
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            const hash: [32]u8 = hash_slice[0..32].*;
            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Look up preimage at the specified timeslot
            span.debug("Looking up preimage", .{});
            const preimage = service_account.?.getPreimage(hash) orelse {
                // Preimage not found, return error status
                span.debug("Preimage not found, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE); // Item does not exist
                return .play;
            };

            // Determine what to read from the preimage
            const f = @min(offset, preimage.len);
            const l = @min(limit, preimage.len - offset);
            span.debug("Preimage found, length: {d}, returning range {d}..{d} ({d} bytes)", .{
                preimage.len, f, f + l, l,
            });

            // Write length to memory first (this implicitly checks if the memory is writable)
            span.debug("Writing preimage to memory at 0x{x}", .{output_ptr});
            exec_ctx.memory.writeSlice(@truncate(output_ptr), preimage[f..][0..l]) catch {
                span.err("Memory access failed while writing preimage", .{});
                return .{ .terminal = .panic };
            };

            // Success result
            exec_ctx.registers[7] = preimage.len; // Success status
            span.debug("Lookup successful, returning length: {d}", .{preimage.len});
            return .play;
        }

        /// Host call implementation for write storage (Ω_W)
        fn writeStorage(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const span = trace.span(.host_call_write);
            defer span.deinit();

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            // Get registers per graypaper B.7: (k_o, k_z, v_o, v_z)
            const k_o = exec_ctx.registers[7]; // Key offset
            const k_z = exec_ctx.registers[8]; // Key size
            const v_o = exec_ctx.registers[9]; // Value offset
            const v_z = exec_ctx.registers[10]; // Value size

            span.debug("Host call: write storage for service {d}", .{host_ctx.service_id});
            span.debug("Key ptr: 0x{x}, Key size: {d}, Value ptr: 0x{x}, Value size: {d}", .{
                k_o, k_z, v_o, v_z,
            });

            // Get service account - always use the current service for writing
            span.debug("Looking up service account", .{});
            const service_account = host_ctx.context.service_accounts.getAccount(host_ctx.service_id) orelse {
                // Service not found, should never happen but handle gracefully
                span.err("Service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Read key data from memory
            span.debug("Reading key data from memory at 0x{x} (len={})", .{ k_o, k_z });
            const key_data = exec_ctx.memory.readSlice(@truncate(k_o), @truncate(k_z)) catch {
                span.err("Memory access failed while reading key data", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Key data: {s}", .{std.fmt.fmtSliceHexLower(key_data)});

            // Construct storage key: H(E_4(service_id) ⌢ key_data)
            span.debug("Constructing storage key", .{});
            var key_input = std.ArrayList(u8).init(host_ctx.allocator);
            defer key_input.deinit();

            // Add service ID as bytes (4 bytes in little-endian)
            var service_id_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &service_id_bytes, host_ctx.service_id, .little);
            key_input.appendSlice(&service_id_bytes) catch {
                span.err("Failed to append service ID to key input", .{});
                return .{ .terminal = .panic };
            };

            // Add key data
            key_input.appendSlice(key_data) catch {
                span.err("Failed to append key data to key input", .{});
                return .{ .terminal = .panic };
            };

            // Hash to get final storage key
            var storage_key: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(key_input.items, &storage_key, .{});
            span.trace("Generated storage key: {s}", .{std.fmt.fmtSliceHexLower(&storage_key)});

            // Check if this is a removal operation (v_z == 0)
            if (v_z == 0) {
                span.debug("Removal operation detected (v_z = 0)", .{});
                // Remove the key from storage
                if (service_account.storage.fetchRemove(storage_key)) |*entry| {
                    // Return the previous length
                    span.debug("Key found and removed, previous value length: {d}", .{entry.value.len});
                    exec_ctx.registers[7] = entry.value.len;
                    host_ctx.allocator.free(entry.value);
                    return .play;
                }
                span.debug("Key not found, returning 0", .{});
                exec_ctx.registers[7] = 0;
                return .play;
            }

            // Get current value length if key exists
            var existing_len: u64 = 0;
            if (service_account.storage.get(storage_key)) |existing_value| {
                existing_len = existing_value.len;
                span.debug("Existing value found, length: {d}", .{existing_len});
            } else {
                span.debug("No existing value found", .{});
            }

            // Read value from memory
            span.debug("Reading value data from memory at 0x{x} len={d}", .{ v_o, v_z });
            const value = exec_ctx.memory.readSlice(@truncate(v_o), @truncate(v_z)) catch {
                span.err("Memory access failed while reading value data", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Value data (first 32 bytes max): {s}", .{
                std.fmt.fmtSliceHexLower(value[0..@min(32, value.len)]),
            });

            // Check if service has enough balance to store this data
            span.debug("Checking storage footprint against balance", .{});
            const footprint = service_account.storageFootprint();
            if (footprint.a_t > service_account.balance) {
                span.debug("Insufficient balance for storage, returning FULL", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.FULL);
                return .play;
            }

            // Write to storage
            span.debug("Writing to storage, value size: {d}", .{value.len});
            service_account.writeStorage(storage_key, value) catch {
                span.err("Failed to write to storage, returning FULL", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.FULL);
                return .play;
            };

            // Return the previous length per graypaper
            span.debug("Storage write successful, returning previous length: {d}", .{existing_len});
            exec_ctx.registers[7] = existing_len;
            return .play;
        }

        /// Host call implementation for transfer (Ω_T)
        fn transfer(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const span = trace.span(.host_call_transfer);
            defer span.deinit();

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            // Get registers per graypaper B.7: [d, a, l, o]
            const destination_id = exec_ctx.registers[7]; // Destination service ID
            const amount = exec_ctx.registers[8]; // Amount to transfer
            const gas_limit = exec_ctx.registers[9]; // Gas limit for on_transfer
            const memo_ptr = exec_ctx.registers[10]; // Pointer to memo data

            span.debug("Host call: transfer from service {d} to {d}", .{
                host_ctx.service_id, destination_id,
            });
            span.debug("Amount: {d}, Gas limit: {d}, Memo ptr: 0x{x}", .{
                amount, gas_limit, memo_ptr,
            });

            // Get source service account
            span.debug("Looking up source service account", .{});
            const source_service = host_ctx.context.service_accounts.getAccount(host_ctx.service_id) orelse {
                span.err("Source service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Check if destination service exists
            span.debug("Looking up destination service account", .{});
            const destination_service = host_ctx.context.service_accounts.getAccount(@intCast(destination_id)) orelse {
                span.debug("Destination service not found, returning WHO error", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.WHO); // Error: destination not found
                return .play;
            };

            // Check if gas limit is high enough for destination service's on_transfer
            span.debug("Checking gas limit against destination service's min_gas_on_transfer: {d}", .{
                destination_service.min_gas_on_transfer,
            });
            if (gas_limit < destination_service.min_gas_on_transfer) {
                span.debug("Gas limit too low, returning LOW error", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.LOW); // Error: gas limit too low
                return .play;
            }

            // Check if source has enough balance
            span.debug("Checking source balance: {d} against transfer amount: {d}", .{
                source_service.balance, amount,
            });
            if (source_service.balance < amount) {
                span.debug("Insufficient balance, returning CASH error", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.CASH); // Error: insufficient funds
                return .play;
            }

            // Read memo data from memory
            span.debug("Reading memo data from memory at 0x{x}", .{memo_ptr});
            const memo_slice = exec_ctx.memory.readSlice(@truncate(memo_ptr), params.transfer_memo_size) catch {
                span.err("Memory access failed while reading memo data", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Memo data (first 32 bytes max): {s}", .{
                std.fmt.fmtSliceHexLower(memo_slice[0..@min(32, memo_slice.len)]),
            });

            // Create a memo buffer and copy data from memory
            var memo: [128]u8 = [_]u8{0} ** 128;
            @memcpy(memo[0..@min(memo_slice.len, 128)], memo_slice[0..@min(memo_slice.len, 128)]);

            // Create a deferred transfer
            span.debug("Creating deferred transfer", .{});
            const deferred_transfer = DeferredTransfer{
                .sender = host_ctx.service_id,
                .destination = @intCast(destination_id),
                .amount = @intCast(amount),
                .memo = memo,
                .gas_limit = @intCast(gas_limit),
            };

            // Add the transfer to the list of deferred transfers
            span.debug("Adding transfer to deferred transfers list", .{});
            host_ctx.deferred_transfers.append(deferred_transfer) catch {
                // Out of memory
                span.err("Failed to append transfer to list, out of memory", .{});
                return .{ .terminal = .panic };
            };

            // Deduct the amount from the source service's balance
            span.debug("Deducting {d} from source service balance", .{amount});
            source_service.balance -= @intCast(amount);

            // Return success
            span.debug("Transfer scheduled successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.OK);
            return .play;
        }

        /// Host call implementation for new service (Ω_N)
        fn newService(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const span = trace.span(.host_call_new_service);
            defer span.deinit();

            if (call_ctx == null) {
                span.err("Call context is null, this should never happen", .{});
                return .{ .terminal = .panic };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const code_hash_ptr = exec_ctx.registers[7];
            const code_len: u32 = @truncate(exec_ctx.registers[8]);
            const min_gas_limit = exec_ctx.registers[9];
            const min_memo_gas = exec_ctx.registers[10];

            span.debug("Host call: new service from service {d}", .{host_ctx.service_id});
            span.debug("Code hash ptr: 0x{x}, Code len: {d}", .{ code_hash_ptr, code_len });
            span.debug("Min gas limit: {d}, Min memo gas: {d}", .{ min_gas_limit, min_memo_gas });

            // Read code hash from memory
            span.debug("Reading code hash from memory at 0x{x}", .{code_hash_ptr});
            const code_hash_slice = exec_ctx.memory.readSlice(@truncate(code_hash_ptr), 32) catch {
                span.err("Memory access failed while reading code hash", .{});
                return .{ .terminal = .panic };
            };
            const code_hash: [32]u8 = code_hash_slice[0..32].*;
            span.trace("Code hash: {s}", .{std.fmt.fmtSliceHexLower(&code_hash)});

            // Check if the calling service has enough balance for the initial funding
            span.debug("Looking up calling service account", .{});
            const calling_service = host_ctx.context.service_accounts.getAccount(host_ctx.service_id) orelse {
                span.err("Calling service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Calculate the minimum balance threshold for a new service (a_t)
            span.debug("Calculating initial balance for new service", .{});
            const initial_balance: types.Balance = params.basic_service_balance + // B_S
                // 2 * one lookup item + 0 storage items
                (params.min_balance_per_item * ((2 * 1) + 0)) +
                // 81 + code_len for preimage lookup length, 0 for storage items
                params.min_balance_per_octet * (81 + code_len + 0);

            span.debug("Initial balance required: {d}, caller balance: {d}", .{
                initial_balance, calling_service.balance,
            });

            if (calling_service.balance < initial_balance) {
                span.debug("Insufficient balance to create new service, returning CASH error", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.CASH); // Error: Insufficient funds
                return .play;
            }

            // Create the new service account
            span.debug("Creating new service account with ID: {d}", .{host_ctx.new_service_id});
            var new_account = host_ctx.context.service_accounts.getOrCreateAccount(host_ctx.new_service_id) catch {
                span.err("Failed to create new service account", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Setting new account properties", .{});
            new_account.code_hash = code_hash;
            new_account.min_gas_accumulate = min_gas_limit;
            new_account.min_gas_on_transfer = min_memo_gas;
            new_account.balance = initial_balance;

            span.debug("Integrating preimage lookup", .{});
            new_account.integratePreimageLookup(code_hash, code_len, null) catch {
                span.err("Failed to integrate preimage lookup, out of memory", .{});
                return .{ .terminal = .panic };
            };

            // Deduct the initial balance from the calling service
            span.debug("Deducting {d} from calling service balance", .{initial_balance});
            calling_service.balance -= initial_balance;

            // Success result
            span.debug("Service created successfully, returning service ID: {d}", .{
                host_ctx.new_service_id,
            });
            exec_ctx.registers[7] = check(host_ctx.context.service_accounts, host_ctx.new_service_id); // Return the new service ID on success
            return .play;
        }
    };
}
