const std = @import("std");

const types = @import("../types.zig");
const state = @import("../state.zig");

const pvm = @import("../pvm.zig");
const pvm_invocation = @import("../pvm/invocation.zig");

const Params = @import("../jam_params.zig").Params;

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
    // Look up the service account
    const service_account = context.service_accounts.getAccount(service_id) orelse {
        return error.ServiceNotFound;
    };

    // Prepare accumulation arguments
    var args_buffer = std.ArrayList(u8).init(allocator);
    defer args_buffer.deinit();

    // Serialize the timeslot (tau) as first argument
    try args_buffer.writer().writeInt(types.TimeSlot, tau, .little);

    // Serialize the service ID
    try args_buffer.writer().writeInt(types.ServiceId, service_id, .little);

    // Serialize the operands
    const operands_count: u32 = @intCast(accumulation_operands.len);
    try args_buffer.writer().writeInt(u32, operands_count, .little);

    for (accumulation_operands) |operand| {
        // Add work_package_hash
        try args_buffer.appendSlice(&operand.work_package_hash);

        // Add payload_hash
        try args_buffer.appendSlice(&operand.payload_hash);

        // Add authorization output
        try args_buffer.writer().writeInt(u32, @intCast(operand.authorization_output.len), .little);
        try args_buffer.appendSlice(operand.authorization_output);

        // Add the output or error
        switch (operand.output) {
            .success => |data| {
                // Write tag 0 for success
                try args_buffer.writer().writeByte(0);
                try args_buffer.writer().writeInt(u32, @intCast(data.len), .little);
                try args_buffer.appendSlice(data);
            },
            .err => |err_code| {
                // Write error code tag (1-5)
                const code: u8 = switch (err_code) {
                    .OutOfGas => 1,
                    .ProgramTermination => 2,
                    .InvalidExportCount => 3,
                    .ServiceCodeUnavailable => 4,
                    .ServiceCodeTooLarge => 5,
                };
                try args_buffer.writer().writeByte(code);
            },
        }
    }

    // FIXME: make this map at compile time
    // Set up host call functions
    var host_call_map = std.AutoHashMapUnmanaged(u32, pvm.PVM.HostCallFn){};
    // errdefer host_call_map.deinit(allocator); // host_call_map will be owned by ExecutionContext

    const host_calls = AccumulateHostCalls(params);

    // Register host calls
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
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.transfer), host_calls.callTransfer);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.eject), host_calls.ejectService);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.query), host_calls.queryPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.solicit), host_calls.solicitPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.forget), host_calls.forgetPreimage);
    // try host_call_map.put(allocator, @intFromEnum(HostCallId.yield), host_calls.yieldAccumulateResult);

    // Initialize host call context B.6
    var host_call_context = AccumulateHostCalls(params).Context{
        .allocator = allocator,
        .service_id = service_id,
        .context = context,
        .new_service_id = generateServiceId(context.service_accounts, service_id, entropy, tau),
        .deferred_transfers = std.ArrayList(DeferredTransfer).init(allocator),
        .accumulation_output = null,
    };
    defer host_call_context.deinit();

    // Execute the PVM invocation
    const code = service_account.getPreimage(service_account.code_hash) orelse {
        return error.ServiceCodeNotAvailable;
    };

    const result = try pvm_invocation.machineInvocation(
        allocator,
        code,
        5, // Accumulation entry point index per section 9.1
        @intCast(gas_limit),
        args_buffer.items,
        host_call_map,
        @ptrCast(&host_call_context),
    );

    _ = result;

    // Calculate gas used
    const gas_used = 10; // FIXME: add gas calc here
    // Build the result array of deferred transfers
    const transfers = try host_call_context.deferred_transfers.toOwnedSlice();

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
    // If the ID is not already used, return it
    if (service_accounts.getAccount(candidate_id) == null) {
        return candidate_id;
    }

    // Otherwise, calculate the next candidate in the sequence
    // The formula is: check((i - 2^8 + 1) mod (2^32 - 2^9) + 2^8)
    const next_id = 0x100 + ((candidate_id - 0x100 + 1) % (std.math.maxInt(u32) - 0x200));

    // Recursive call to check the next candidate
    return check(service_accounts, next_id);
}

/// Generates a deterministic service ID based on creator service, entropy, and timeslot
/// As defined in B.9 of the graypaper
fn generateServiceId(service_accounts: *state.Delta, creator_id: types.ServiceId, entropy: [32]u8, timeslot: u32) types.ServiceId {
    // Create input for hash: service ID + entropy + timeslot
    var hash_input: [32 + 32 + 4]u8 = undefined;

    // Copy service ID as bytes (4 bytes in little-endian format)
    std.mem.writeInt(u32, hash_input[0..4], creator_id, .little);

    // Copy entropy (32 bytes)
    std.mem.copyForwards(u8, hash_input[4..36], &entropy);

    // Copy timeslot (4 bytes in little-endian format)
    std.mem.writeInt(u32, hash_input[36..40], timeslot, .little);

    // Hash the input using Blake2b-256
    var hash_output: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(&hash_input, &hash_output, .{});

    // Generate initial ID: take first 4 bytes of hash mod (2^32 - 2^9) + 2^8
    const initial_value = std.mem.readInt(u32, hash_output[0..4], .little);
    const candidate_id = 0x100 + (initial_value % (std.math.maxInt(u32) - 0x200));

    // Check if this ID is available, and find next available if not
    return check(service_accounts, candidate_id);
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
            _ = call_ctx;
            exec_ctx.registers[7] = @intCast(exec_ctx.gas - 10);

            return .play;
        }

        /// Host call implementation for lookup preimage (Ω_L)
        fn lookupPreimage(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const service_id = exec_ctx.registers[7];
            const hash_ptr = exec_ctx.registers[8];
            const output_ptr = exec_ctx.registers[9];
            const offset = exec_ctx.registers[10];
            const limit = exec_ctx.registers[11];

            // Get service account based on special cases as per graypaper
            const service_account = if (service_id == host_ctx.service_id or service_id == 0xFFFFFFFFFFFFFFFF)
                // Special case: current service or 2^64-1 value
                host_ctx.context.service_accounts.getAccount(host_ctx.service_id)
            else
                // Regular case: look up by service_id
                host_ctx.context.service_accounts.getAccount(@intCast(service_id));

            if (service_account == null) {
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE); // Index unknown
                return .play;
            }

            // Read hash from memory (access verification is implicit)
            const hash_slice = exec_ctx.memory.readSlice(@truncate(hash_ptr), 32) catch {
                // Error: memory access failed
                return .{ .terminal = .panic };
            };

            const hash: [32]u8 = hash_slice[0..32].*;

            // Look up preimage at the specified timeslot
            const preimage = service_account.?.getPreimage(hash) orelse {
                // Preimage not found, return error status
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE); // Item does not exist
                return .play;
            };

            // Determine what to read from the preimage
            const f = @min(offset, preimage.len);
            const l = @min(limit, preimage.len - offset);

            // Write length to memory first (this implicitly checks if the memory is writable)
            exec_ctx.memory.writeSlice(@truncate(output_ptr), preimage[f..][0..l]) catch {
                return .{ .terminal = .panic };
            };

            // Success result
            exec_ctx.registers[7] = preimage.len; // Success status
            return .play;
        }

        /// Host call implementation for write storage (Ω_W)
        fn writeStorage(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            // Get registers per graypaper B.7: (k_o, k_z, v_o, v_z)
            const k_o = exec_ctx.registers[7]; // Key offset
            const k_z = exec_ctx.registers[8]; // Key size
            const v_o = exec_ctx.registers[9]; // Value offset
            const v_z = exec_ctx.registers[10]; // Value size

            // Get service account - always use the current service for writing
            const service_account = host_ctx.context.service_accounts.getAccount(host_ctx.service_id) orelse {
                // Service not found, should never happen but handle gracefully
                return .{ .terminal = .panic };
            };

            // Read key data from memory
            const key_data = exec_ctx.memory.readSlice(@truncate(k_o), @truncate(k_z)) catch {
                return .{ .terminal = .panic };
            };

            // Construct storage key: H(E_4(service_id) ⌢ key_data)
            var key_input = std.ArrayList(u8).init(host_ctx.allocator);
            defer key_input.deinit();

            // Add service ID as bytes (4 bytes in little-endian)
            var service_id_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &service_id_bytes, host_ctx.service_id, .little);
            key_input.appendSlice(&service_id_bytes) catch {
                return .{ .terminal = .panic };
            };

            // Add key data
            key_input.appendSlice(key_data) catch {
                return .{ .terminal = .panic };
            };

            // Hash to get final storage key
            var storage_key: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(key_input.items, &storage_key, .{});

            // Check if this is a removal operation (v_z == 0)
            if (v_z == 0) {
                // Remove the key from storage
                if (service_account.storage.fetchRemove(storage_key)) |*entry| {
                    // Return the previous length
                    exec_ctx.registers[7] = entry.value.len;
                    host_ctx.allocator.free(entry.value);
                    return .play;
                }
                exec_ctx.registers[7] = 0;
                return .play;
            }

            // Get current value length if key exists
            var existing_len: u64 = 0;
            if (service_account.storage.get(storage_key)) |existing_value| {
                existing_len = existing_value.len;
            }

            // Read value from memory
            const value_slice = exec_ctx.memory.readSlice(@truncate(v_o), @truncate(v_z)) catch {
                return .{ .terminal = .panic };
            };

            // Create a copy of the value data
            const value = host_ctx.allocator.dupe(u8, value_slice) catch {
                return .{ .terminal = .panic };
            };
            errdefer host_ctx.allocator.free(value);

            // Check if service has enough balance to store this data
            // This is a simplification - proper implementation would calculate
            // the balance threshold based on the new storage size
            const footprint = service_account.storageFootprint();
            if (footprint.a_t > service_account.balance) {
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.FULL);
                return .play;
            }

            // Write to storage
            service_account.writeStorage(storage_key, value) catch {
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.FULL);
                return .play;
            };

            // Return the previous length per graypaper
            exec_ctx.registers[7] = existing_len;
            return .play;
        }

        /// Host call implementation for new service (Ω_N)
        fn newService(
            exec_ctx: *pvm.PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) pvm.PVM.HostCallResult {
            if (call_ctx == null) {
                return .{ .terminal = .panic };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const code_hash_ptr = exec_ctx.registers[7];
            const code_len: u32 = @truncate(exec_ctx.registers[8]);
            const min_gas_limit = exec_ctx.registers[9];
            const min_memo_gas = exec_ctx.registers[10];

            // Read code hash from memory
            const code_hash_slice = exec_ctx.memory.readSlice(@truncate(code_hash_ptr), 32) catch {
                // if (err == pvm.PVM.Memory.Error.PageFault) {
                //     return .{ .terminal = .{ .page_fault = exec_ctx.memory.last_violation.?.address } };
                // }
                // Unknown error
                return .{ .terminal = .panic };
            };
            const code_hash: [32]u8 = code_hash_slice[0..32].*;

            // Check if the calling service has enough balance for the initial funding
            const calling_service = host_ctx.context.service_accounts.getAccount(host_ctx.service_id) orelse {
                // Error: Service not found
                return .{ .terminal = .panic };
            };

            // Calculate the minimum balance threshold for a new service (a_t)
            const initial_balance: types.Balance = params.basic_service_balance + // B_S
                // 2 * one lookup item + 0 storage items
                (params.min_balance_per_item * ((2 * 1) + 0)) +
                // 81 + code_len for preimage lookup length, 0 for storage items
                params.min_balance_per_octet * (81 + code_len + 0);

            if (calling_service.balance < initial_balance) {
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.CASH); // Error: Insufficient funds
                return .play;
            }

            // Create the new service account
            var new_account = host_ctx.context.service_accounts.getOrCreateAccount(host_ctx.new_service_id) catch {
                // Error: for some reason failing to create a new account
                return .{ .terminal = .panic };
            };

            new_account.code_hash = code_hash;
            new_account.min_gas_accumulate = min_gas_limit;
            new_account.min_gas_on_transfer = min_memo_gas;

            new_account.balance = initial_balance;

            new_account.integratePreimageLookup(code_hash, code_len, null) catch {
                // Error: integratePreimageLookup failed, cause OOM
                return .{ .terminal = .panic };
            };

            // Deduct the initial balance from the calling service
            calling_service.balance -= initial_balance;

            // Success result
            exec_ctx.registers[7] = check(host_ctx.context.service_accounts, host_ctx.new_service_id); // Return the new service ID on success
            return .play;
        }
    };
}
