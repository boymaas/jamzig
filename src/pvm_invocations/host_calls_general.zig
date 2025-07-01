const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const state_keys = @import("../state_keys.zig");
const PVM = @import("../pvm.zig").PVM;
const Params = @import("../jam_params.zig").Params;

const DeltaSnapshot = @import("../services_snapshot.zig").DeltaSnapshot;

const ReturnCode = @import("host_calls.zig").ReturnCode;

// Add tracing import
const trace = @import("../tracing.zig").scoped(.host_calls);

// Type aliases for convenience
const Hash256 = types.Hash;

/// Work item metadata for enhanced fetch selectors
pub const WorkItemMetadata = struct {
    service_id: types.ServiceId,
    code_hash: types.Hash,
    payload_hash: types.Hash,
    gas_limit_refine: types.Gas,
    gas_limit_accumulate: types.Gas,
    export_count: u32,
    import_count: u32,
};

/// General host calls following the same pattern as accumulate
pub fn GeneralHostCalls(comptime params: Params) type {
    return struct {
        /// Optional invocation-specific context for extended fetch selectors
        pub const InvocationContext = union(enum) {
            accumulate: AccumulateData,
            // REMOVED FOR REFINE: refine: RefineData,
            ontransfer: OnTransferData,

            pub const AccumulateData = struct {
                // Reference to accumulate context containing all accumulation data
                accumulate_context: *@import("accumulate/context.zig").AccumulationContext(params),
                // Additional data not in the context
                transfers: ?[]const @import("accumulate/types.zig").DeferredTransfer = null,
            };

            pub const OnTransferData = struct {
                // Limited data available in transfer context
                // Could include transfer-specific information
                transfer_memo: ?[]const u8 = null,
                // Transfer sequence for selectors 16-17
                transfer_sequence: ?[]const @import("accumulate/types.zig").DeferredTransfer = null,
            };
        };

        /// Context for general host calls
        pub const Context = struct {
            /// The current service ID
            service_id: types.ServiceId,
            /// Reference to service accounts delta snapshot
            service_accounts: *DeltaSnapshot, // d ∈ D⟨N_S → A⟩
            /// Allocator for memory allocation
            allocator: std.mem.Allocator,
            /// Optional invocation-specific context for extended fetch selectors
            invocation_context: ?InvocationContext = null,

            const Self = @This();

            pub fn init(
                service_id: types.ServiceId,
                service_accounts: *DeltaSnapshot,
                allocator: std.mem.Allocator,
            ) Self {
                return Self{
                    .service_id = service_id,
                    .service_accounts = service_accounts,
                    .allocator = allocator,
                    .invocation_context = null, // Default: no extended context
                };
            }

            pub fn initWithContext(
                service_id: types.ServiceId,
                service_accounts: *DeltaSnapshot,
                allocator: std.mem.Allocator,
                invocation_context: InvocationContext,
            ) Self {
                return Self{
                    .service_id = service_id,
                    .service_accounts = service_accounts,
                    .allocator = allocator,
                    .invocation_context = invocation_context,
                };
            }
        };

        /// Encode transfers array
        fn encodeTransfers(allocator: std.mem.Allocator, transfers: []const @import("accumulate/types.zig").DeferredTransfer) ![]u8 {
            const codec = @import("../codec.zig");
            return try codec.serializeAlloc([]const @import("accumulate/types.zig").DeferredTransfer, .{}, allocator, transfers);
        }

        /// Encode single transfer
        fn encodeTransfer(allocator: std.mem.Allocator, transfer: *const @import("accumulate/types.zig").DeferredTransfer) ![]u8 {
            const codec = @import("../codec.zig");
            return try codec.serializeAlloc(@import("accumulate/types.zig").DeferredTransfer, .{}, allocator, transfer.*);
        }

        /// Encode outputs array
        fn encodeOutputs(allocator: std.mem.Allocator, outputs: []const types.AccumulateOutput) ![]u8 {
            const codec = @import("../codec.zig");
            return try codec.serializeAlloc([]const types.AccumulateOutput, .{}, allocator, outputs);
        }

        /// Encode operand tuples array
        fn encodeOperandTuples(allocator: std.mem.Allocator, operand_tuples: []const @import("accumulate.zig").AccumulationOperand) ![]u8 {
            const codec = @import("../codec.zig");
            return try codec.serializeAlloc([]const @import("accumulate.zig").AccumulationOperand, .{}, allocator, operand_tuples);
        }

        /// Encode single operand tuple
        fn encodeOperandTuple(allocator: std.mem.Allocator, operand_tuple: *const @import("accumulate.zig").AccumulationOperand) ![]u8 {
            const codec = @import("../codec.zig");
            return try codec.serializeAlloc(@import("accumulate.zig").AccumulationOperand, .{}, allocator, operand_tuple.*);
        }

        //
        // Fetch Host Function (ΩY) - Host Call ID: 18
        //
        // Provides context-aware data access to PVM programs across different invocation contexts.
        // The function uses register ω10 as a selector to determine which of 17 cases to execute.
        //
        // Gas Cost: 10
        //
        // Parameters:
        // - ϱ: Gas remaining
        // - ω: Registers (ω7 = output offset, ω8 = first byte offset, ω9 = length limit, ω10 = case selector, ω11-12 = indices)
        // - µ: Memory
        // - (m, e): PVM context (for Refine invocation)
        // - p: Work package (available in Refine context)
        // - n: Entropy/nonce (available in Is-Authorized and Accumulate contexts)
        // - r: Refinement context (available in Refine context)
        // - i: Import segments sequence (available in Refine context)
        // - i: Current work item index (available in Refine context)
        // - x: Extrinsic data segments (available in Refine context)
        // - o: Operand tuples sequence (available in Accumulate context)
        // - t: Transfer sequence (available in On-Transfer context)
        //
        // Cases (by ω10 value):
        //
        // === Universal Cases (All Contexts) ===
        // 0: SYSTEM CONSTANTS - Returns encoded system parameters (BI, BL, BS, C, D, E, GA, GI, GR, GT, H, I, J, L, O, P, Q, R, S, T, U, V, WA, WB, WC, WE, WG, WM, WP, WR, WT, WX, Y)
        //    Used by: All contexts for system limits and parameters
        //
        //    BI: min_balance_per_item (10)
        //    BL: min_balance_per_octet (1)
        //    BS: basic_service_balance (100)
        //    C: core_count (341)
        //    D: preimage_expungement_period (28_800)
        //    E: epoch_length (600)
        //    GA: gas_alloc_accumulation (10_000_000)
        //    GI: gas_alloc_is_authorized (1_000_000)
        //    GR: gas_alloc_refine (500_000_000)
        //    GT: total_gas_alloc_accumulation (35_000_000)
        //    H: recent_history_size (8)
        //    I: max_work_items_per_package (16)
        //    J: max_number_of_dependencies_for_work_reports (8)
        //    L: max_lookup_anchor_age (14_400)
        //    O: max_authorizations_pool_items (8)
        //    P: slot_period (6)
        //    Q: max_authorizations_queue_items (80)
        //    R: validator_rotation_period (10)
        //    S: max_accumulation_queue_entries (1024)
        //    T: max_number_of_extrinsics
        //    U: work_replacement_period (5)
        //    V: validators_count (1023)
        //    WA: max_authorization_code_size (64_000)
        //    WB: max_work_package_size
        //    WC: max_service_code_size (4_000_000)
        //    WE: erasure_coded_piece_size (684)
        //    WG: exported_segment_size
        //    WM: max_manifest_entries (2^11)
        //    WP: max_work_package_size (12 * 2^20)
        //    WR: max_work_report_size (96 * 2^10)
        //    WT: transfer_memo_size (128)
        //    WX: max_number_of_exports
        //    Y: ticket_submission_end_epoch_slot (500)
        //    Used by: All contexts for system limits and parameters
        //
        // === Is-Authorized & Accumulate Context ===
        // 1: ENTROPY - Returns entropy value n for randomness
        //    Used by: Is-Authorized and Accumulate for random number generation
        //
        // === Refine Context Only ===
        // 2: REFINEMENT CONTEXT - Returns refinement context r
        // 3: IMPORT SEGMENT DATA - Returns x[ω11][ω12] (specific import segment)
        // 4: IMPORT SEGMENT BY WORK ITEM - Returns x[i][ω11] (import for current work item)
        // 5: IMPORT JUSTIFICATION DATA - Returns i[ω11][ω12] (justification data)
        // 6: IMPORT JUSTIFICATION BY WORK ITEM - Returns i[i][ω11] (justification for current work item)
        // 7: ENCODED WORK PACKAGE - Returns E(p) (entire work package encoded)
        // 8: WORK PACKAGE HEADER - Returns E(pu, ↕pp) (authorization and parameterization)
        // 9: WORK PACKAGE CONTEXT - Returns pj (work package justification)
        // 10: WORK PACKAGE EXTRINSIC - Returns px (extrinsic data)
        // 11: ENCODED WORK ITEMS LIST - Returns E(↕[S(w) | w <- pw]) (all work items summary)
        // 12: SPECIFIC WORK ITEM SUMMARY - Returns S(pw[ω11]) (work item at index ω11)
        // 13: WORK ITEM PAYLOAD - Returns pw[ω11]y (payload of work item at ω11)
        //
        // === Accumulate Context Only ===
        // 14: ENCODED OPERAND TUPLES - Returns E(↕o) (all operand tuples for accumulation)
        //     Used by: Accumulate to access all work items being processed
        // 15: SPECIFIC OPERAND TUPLE - Returns E(o[ω11]) (operand tuple at index ω11)
        //     Used by: Accumulate to access individual work item data
        //
        // === On-Transfer Context Only ===
        // 16: ENCODED TRANSFER SEQUENCE - Returns E(↕t) (all pending transfers)
        //     Used by: On-Transfer to access all transfers to process
        // 17: SPECIFIC TRANSFER - Returns E(t[ω11]) (transfer at index ω11)
        //     Used by: On-Transfer to access individual transfer details
        //
        // Return Behavior:
        // - Writes result to memory at µ[o:o+l] where o=ω7, l=min(ω9, |v|-f), f=min(ω8, |v|)
        // - Sets ω'7 to the actual length of data (or NONE if no data)
        // - Returns ∅ for cases where required context data is unavailable
        // - Triggers page fault (☇) if output range is not writable
        //
        // Error Conditions:
        // - ε' = ☇ if output memory range No:o+l is not writable
        // - ω'7 = NONE if requested data is not available in current context
        //
        // Work Item Summary Format S(w):
        // E(E4(ws), wh, E8(wg, wa), E2(we, |wi|, |wx|), E4(|wy|))
        // Contains: service id, hash, gas/argument, extrinsic flags, and payload length
        //
        pub fn fetch(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_fetch);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const output_ptr = exec_ctx.registers[7]; // Output pointer (o)
            const offset = exec_ctx.registers[8]; // Offset (f)
            const limit = exec_ctx.registers[9]; // Length limit (l)
            const selector = exec_ctx.registers[10]; // Data selector

            span.debug("Host call: fetch selector={d}", .{selector});
            span.debug("Output ptr: 0x{x}, offset: {d}, limit: {d}", .{ output_ptr, offset, limit });

            // Determine what data to fetch based on selector
            var data_to_fetch: ?[]const u8 = null;
            var needs_cleanup = false;

            switch (selector) {
                0 => {
                    // Return JAM parameters as encoded bytes per graypaper
                    span.debug("Encoding JAM chain constants", .{});

                    const encoded_constants = encodeJamParams(host_ctx.allocator, params) catch {
                        span.err("Failed to encode JAM chain constants", .{});
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    };

                    data_to_fetch = encoded_constants;
                    needs_cleanup = true;
                },

                1 => {
                    // Selector 1: Entropy (η) - available in accumulate context
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            // REMOVED FOR REFINE: .refine case
                            .accumulate => |acc_data_| {
                                const acc_data: InvocationContext.AccumulateData = acc_data_;
                                span.debug("Entropy available from accumulate context", .{});
                                data_to_fetch = acc_data.accumulate_context.entropy[0..];
                            },
                            else => {
                                span.debug("Entropy not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Entropy fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                2 => {
                    // Selector 2: Authorizer hash output (ω) - context-aware
                    // Returns the 32-byte Blake2s hash of the authorization-output
                    // of the authorizer for the current work package operand being processed
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            .accumulate => |acc_data_| {
                                const acc_data: InvocationContext.AccumulateData = acc_data_;
                                // Use context-aware authorizer hash from accumulate context
                                if (acc_data.accumulate_context.getCurrentAuthorizerHash()) |authorizer_hash| {
                                    span.debug("Context-aware authorizer hash available from current operand", .{});
                                    data_to_fetch = authorizer_hash[0..];
                                } else {
                                    span.debug("Context-aware authorizer hash not available", .{});
                                }
                            },
                            else => {
                                span.debug("Authorizer hash not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Authorizer hash fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                // REMOVED FOR REFINE: Selectors 3-13 (work package specific selectors)
                // - Selector 3: Extrinsics by item and byte index
                // - Selector 4: Extrinsics for current work item by byte index
                // - Selector 5: Imports by item and byte index
                // - Selector 6: Imports for current work item by byte index
                // - Selector 7: Encoded work package
                // - Selector 8: Authorization hash and config
                // - Selector 9: Authorization token
                // - Selector 10: Work package context
                // - Selector 11: Work items summary
                // - Selector 12: Specific work item summary
                // - Selector 13: Work item payload
                3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 => {
                    span.debug("Selector {d} disabled (refine-only)", .{selector});
                    exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                    return .play;
                },

                14 => {
                    // Selector 14: Encoded operand tuples
                    // E(↕o) - All operand tuples for accumulation
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            .accumulate => |acc_data_| {
                                const acc_data: InvocationContext.AccumulateData = acc_data_;
                                if (acc_data.accumulate_context.operand_tuples) |operand_tuples| {
                                    // Encode operand tuples array
                                    const operand_tuples_data = encodeOperandTuples(host_ctx.allocator, operand_tuples) catch {
                                        span.err("Failed to encode operand tuples", .{});
                                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                        return .play;
                                    };
                                    span.debug("Operand tuples encoded successfully from accumulate context, count={d}", .{operand_tuples.len});
                                    data_to_fetch = operand_tuples_data;
                                    needs_cleanup = true;
                                } else {
                                    span.debug("Operand tuples not available in accumulate context", .{});
                                }
                            },
                            else => {
                                span.debug("Operand tuples not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Operand tuples fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                15 => {
                    // Selector 15: Specific operand tuple
                    // E(o[ω11]) - Operand tuple at index ω11
                    const operand_index = @as(u32, @intCast(exec_ctx.registers[11]));

                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            .accumulate => |acc_data_| {
                                const acc_data: InvocationContext.AccumulateData = acc_data_;
                                if (acc_data.accumulate_context.operand_tuples) |operand_tuples| {
                                    if (operand_index < operand_tuples.len) {
                                        const operand_tuple = &operand_tuples[operand_index];
                                        const operand_tuple_data = encodeOperandTuple(host_ctx.allocator, operand_tuple) catch {
                                            span.err("Failed to encode operand tuple", .{});
                                            exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                            return .play;
                                        };
                                        span.debug("Operand tuple encoded successfully from accumulate context: index={d}", .{operand_index});
                                        data_to_fetch = operand_tuple_data;
                                        needs_cleanup = true;
                                    } else {
                                        span.debug("Operand tuple index out of bounds in accumulate context: index={d}, count={d}", .{ operand_index, operand_tuples.len });
                                    }
                                } else {
                                    span.debug("Operand tuples not available in accumulate context", .{});
                                }
                            },
                            else => {
                                span.debug("Specific operand tuple not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Specific operand tuple fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                16 => {
                    // Selector 16: Encoded transfer sequence
                    // E(↕t) - All pending transfers
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            .ontransfer => |transfer_data_| {
                                const transfer_data: InvocationContext.OnTransferData = transfer_data_;

                                if (transfer_data.transfer_sequence) |transfer_sequence| {
                                    // Encode transfer sequence array
                                    const transfers_data = encodeTransfers(host_ctx.allocator, transfer_sequence) catch {
                                        span.err("Failed to encode transfer sequence", .{});
                                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                        return .play;
                                    };
                                    span.debug("Transfer sequence encoded successfully from ontransfer context, count={d}", .{transfer_sequence.len});
                                    data_to_fetch = transfers_data;
                                    needs_cleanup = true;
                                } else {
                                    span.debug("Transfer sequence not available in ontransfer context", .{});
                                }
                            },
                            else => {
                                span.debug("Transfer sequence not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Transfer sequence fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                17 => {
                    // Selector 17: Specific transfer
                    // E(t[ω11]) - Transfer at index ω11
                    const transfer_index = @as(u32, @intCast(exec_ctx.registers[11]));

                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            .ontransfer => |transfer_data_| {
                                const transfer_data: InvocationContext.OnTransferData = transfer_data_;
                                if (transfer_data.transfer_sequence) |transfer_sequence| {
                                    if (transfer_index < transfer_sequence.len) {
                                        const transfer = &transfer_sequence[transfer_index];
                                        const transfer_data_encoded = encodeTransfer(host_ctx.allocator, transfer) catch {
                                            span.err("Failed to encode transfer", .{});
                                            exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                            return .play;
                                        };
                                        span.debug("Transfer encoded successfully from ontransfer context: index={d}", .{transfer_index});
                                        data_to_fetch = transfer_data_encoded;
                                        needs_cleanup = true;
                                    } else {
                                        span.debug("Transfer index out of bounds in ontransfer context: index={d}, count={d}", .{ transfer_index, transfer_sequence.len });
                                    }
                                } else {
                                    span.debug("Transfer sequence not available in ontransfer context", .{});
                                }
                            },
                            else => {
                                span.debug("Specific transfer not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Specific transfer fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                else => {
                    // Invalid selector - per JAM spec, selectors are 0-17
                    span.debug("Invalid fetch selector: {d} (valid range: 0-17)", .{selector});
                    exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                    return .play;
                },
            }
            defer if (needs_cleanup and data_to_fetch != null) host_ctx.allocator.free(data_to_fetch.?);

            if (data_to_fetch) |data| {
                // Calculate what to return based on offset and limit
                const f = @min(offset, data.len);
                const l = @min(limit, data.len - f);

                span.debug("Fetching {d} bytes from offset {d}", .{ l, f });

                // Write data to memory
                exec_ctx.memory.writeSlice(@truncate(output_ptr), data[f..][0..l]) catch {
                    span.err("Memory access failed while writing fetch data", .{});
                    return .{ .terminal = .panic };
                };

                // Return the total length of the data
                exec_ctx.registers[7] = data.len;
                span.debug("Fetch successful, total length: {d}", .{data.len});
            } else {
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
            }

            return .play;
        }

        pub fn debugLog(
            exec_ctx: *PVM.ExecutionContext,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_debug_log);
            defer span.deinit();

            // https://hackmd.io/@polkadot/jip1
            const level = switch (exec_ctx.registers[7]) {
                0 => "FATAL_ERROR",
                1 => "WARNING",
                2 => "INFO",
                3 => "HELPFULL_INFO",
                4 => "PENDANTIC",
                else => "UNKOWN_LEVEL",
            };
            var target: PVM.Memory.MemorySlice = if (exec_ctx.registers[8] == 0 and exec_ctx.registers[9] == 0)
                .{ .buffer = &[_]u8{} }
            else
                exec_ctx.memory.readSlice(@truncate(exec_ctx.registers[8]), exec_ctx.registers[9]) catch message: {
                    span.err("Could not access memory for target component", .{});
                    break :message .{ .buffer = &[_]u8{} };
                };
            defer target.deinit();

            var message = exec_ctx.memory.readSlice(@truncate(exec_ctx.registers[10]), exec_ctx.registers[11]) catch {
                span.err("Could not access memory for message component", .{});
                return .play;
            };
            defer message.deinit();

            span.warn("DEBUGLOG {s} {s}: {s}", .{ level, target.buffer, message.buffer });
            return .play;
        }

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_gas);
            defer span.deinit();
            span.debug("Host call: gas remaining", .{});

            exec_ctx.gas -= 10;
            const remaining_gas = exec_ctx.gas;
            exec_ctx.registers[7] = @intCast(remaining_gas);

            span.debug("Remaining gas: {d}", .{remaining_gas});
            return .play;
        }

        /// Host call implementation for lookup preimage (Ω_L)
        pub fn lookupPreimage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_lookup);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

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
                break :blk host_ctx.service_accounts.getReadOnly(host_ctx.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk host_ctx.service_accounts.getReadOnly(@intCast(service_id));
            };

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE); // Index unknown
                return .play;
            }

            // Read hash from memory (access verification is implicit)
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                // Error: memory access failed
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Look up preimage at the specified timeslot
            span.debug("Looking up preimage", .{});
            const actual_service_id = if (service_id == 0xFFFFFFFFFFFFFFFF) host_ctx.service_id else @as(u32, @intCast(service_id));
            const preimage_key = state_keys.constructServicePreimageKey(actual_service_id, hash);
            const preimage = service_account.?.getPreimage(preimage_key) orelse {
                // Preimage not found, return error status
                span.debug("Preimage not found, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE); // Item does not exist
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

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_read);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            // Get registers per graypaper B.7: (s*, k_o, k_z, o)
            const service_id = exec_ctx.registers[7]; // Service ID (s*)
            const k_o = exec_ctx.registers[8]; // Key offset (k_o)
            const k_z = exec_ctx.registers[9]; // Key size (k_z)
            const output_ptr = exec_ctx.registers[10]; // Output buffer pointer (o)
            const offset = exec_ctx.registers[11]; // Offset in the value (f)
            const limit = exec_ctx.registers[12]; // Length limit (l)

            span.debug("Host call: read storage for service {d}", .{service_id});
            span.trace("Key ptr: 0x{x}, Key size: {d}, Output ptr: 0x{x}", .{
                k_o, k_z, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });

            // Get service account based on special cases as per graypaper B.7
            const service_account = if (service_id == 0xFFFFFFFFFFFFFFFF) blk: {
                span.debug("Using current service ID: {d}", .{host_ctx.service_id});
                break :blk host_ctx.service_accounts.getReadOnly(host_ctx.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk host_ctx.service_accounts.getReadOnly(@intCast(service_id));
            };

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            }

            // Read key data from memory
            span.debug("Reading key data from memory at 0x{x} (len={d})", .{ k_o, k_z });
            var key_data = exec_ctx.memory.readSlice(@truncate(k_o), @truncate(k_z)) catch {
                span.err("Memory access failed while reading key data", .{});
                return .{ .terminal = .panic };
            };
            defer key_data.deinit();
            span.trace("Key = {s}", .{std.fmt.fmtSliceHexLower(key_data.buffer)});

            // Hash the key_data first before constructing storage key
            span.debug("Hashing key data", .{});
            var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
            hasher.update(key_data.buffer);
            var key_hash: [32]u8 = undefined;
            hasher.final(&key_hash);

            // Construct storage key using the hash
            span.debug("Constructing PVM storage key", .{});
            const actual_service_id = if (service_id == 0xFFFFFFFFFFFFFFFF) host_ctx.service_id else @as(u32, @intCast(service_id));

            const storage_key = state_keys.constructStorageKey(actual_service_id, key_hash);
            span.trace("Generated PVM storage key: {s}", .{std.fmt.fmtSliceHexLower(&storage_key)});

            // Look up the value in storage
            span.debug("Looking up value in storage", .{});
            const value = service_account.?.storage.get(storage_key) orelse {
                // Key not found
                span.debug("Key not found in storage, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            };

            // Determine what to read from the value
            const f = @min(offset, value.len);
            const l = @min(limit, value.len - f);
            span.debug("Value found, length: {d}, returning range {d}..{d} ({d} bytes) => {s}", .{
                value.len,
                f,
                f + l,
                l,
                std.fmt.fmtSliceHexLower(value[f..][0..l]),
            });

            // Write the value to memory
            span.debug("Writing value to memory at 0x{x}", .{output_ptr});
            exec_ctx.memory.writeSlice(@truncate(output_ptr), value[f..][0..l]) catch {
                span.err("Memory access failed while writing value", .{});
                return .{ .terminal = .panic };
            };

            // Success result
            exec_ctx.registers[7] = value.len;
            span.debug("Read successful, returning length: {d}", .{value.len});
            return .play;
        }

        /// Host call implementation for write storage (Ω_W)
        pub fn writeStorage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_write);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            // Get registers per graypaper B.7: (k_o, k_z, v_o, v_z)
            const k_o = exec_ctx.registers[7]; // Key offset
            const k_z = exec_ctx.registers[8]; // Key size
            const v_o = exec_ctx.registers[9]; // Value offset
            const v_z = exec_ctx.registers[10]; // Value size

            span.debug("Host call: write storage for service {d}", .{host_ctx.service_id});
            span.trace("Key ptr: 0x{x}, Key size: {d}, Value ptr: 0x{x}, Value size: {d}", .{
                k_o, k_z, v_o, v_z,
            });

            // Get service account - always use the current service for writing
            span.debug("Looking up service account", .{});
            const service_account = host_ctx.service_accounts.getMutable(host_ctx.service_id) catch {
                // Service not found, should never happen but handle gracefully
                span.err("Could get create mutable instance of service accounts", .{});
                return .{ .terminal = .panic };
            } orelse {
                // Service not found, should never happen but handle gracefully
                span.err("Service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Read key data from memory
            span.debug("Reading key data from memory at 0x{x} (len={d})", .{ k_o, k_z });
            var key_data = exec_ctx.memory.readSlice(@truncate(k_o), @truncate(k_z)) catch {
                span.err("Memory access failed while reading key data", .{});
                return .{ .terminal = .panic };
            };
            defer key_data.deinit();
            span.trace("Key data: {s}", .{std.fmt.fmtSliceHexLower(key_data.buffer)});

            // Hash the key_data first before constructing storage key
            span.debug("Hashing key data", .{});
            var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
            hasher.update(key_data.buffer);
            var key_hash: [32]u8 = undefined;
            hasher.final(&key_hash);

            // Construct storage key using the hash
            span.debug("Constructing PVM storage key", .{});

            const storage_key = state_keys.constructStorageKey(host_ctx.service_id, key_hash);
            span.trace("Generated PVM storage key: {s}", .{std.fmt.fmtSliceHexLower(&storage_key)});

            // Check if this is a removal operation (v_z == 0)
            if (v_z == 0) {
                span.debug("Removal operation detected (v_z = 0)", .{});
                // Remove the key from storage
                if (service_account.storage.fetchRemove(storage_key)) |*entry| {
                    // Return the previous length
                    span.debug("Key found and removed, previous value: {s} length: {d}", .{ std.fmt.fmtSliceHexLower(entry.value), entry.value.len });
                    exec_ctx.registers[7] = entry.value.len;
                    host_ctx.allocator.free(entry.value);
                    return .play;
                }
                span.debug("Key not found, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            }

            // Read value from memory
            span.trace("Reading value data from memory at 0x{x} len={d}", .{ v_o, v_z });
            var value = exec_ctx.memory.readSlice(@truncate(v_o), @truncate(v_z)) catch {
                span.err("Memory access failed while reading value data", .{});
                return .{ .terminal = .panic };
            };
            defer value.deinit();

            span.debug("Write Key={s} => Data len={d} (first 32 bytes max): {s}", .{
                std.fmt.fmtSliceHexLower(&storage_key),
                value.buffer.len,
                std.fmt.fmtSliceHexLower(value.buffer[0..@min(32, value.buffer.len)]),
            });

            // Write and get the prior value owned
            var maybe_prior_value: ?[]const u8 = pv: {
                const value_owned = host_ctx.allocator.dupe(u8, value.buffer) catch {
                    return .{ .terminal = .panic };
                };
                break :pv service_account.writeStorage(storage_key, value_owned) catch {
                    host_ctx.allocator.free(value_owned);
                    span.err("Failed to write to storage", .{});
                    return .{ .terminal = .panic };
                };
            };
            defer if (maybe_prior_value) |pv| host_ctx.allocator.free(pv);

            if (maybe_prior_value) |prior_value| {
                span.debug("Prior value found: {s}", .{std.fmt.fmtSliceHexLower(prior_value)});
            } else {
                span.debug("No prior value found", .{});
            }

            // Check if service has enough balance to store this data
            const footprint = service_account.storageFootprint();
            span.debug("Checking storage footprint a_t {d} against balance {d}", .{ footprint.a_t, service_account.balance });
            if (footprint.a_t > service_account.balance) {
                span.warn("Insufficient balance for storage, returning FULL", .{});
                // Restore old value, if we had a prior value, otherwise
                // we remove the storage key, as we do not have enough balance
                if (maybe_prior_value) |prior_value| {
                    service_account.writeStorageFreeOldValue(storage_key, prior_value) catch {
                        return .{ .terminal = .panic };
                    };
                    maybe_prior_value = null; // to avoid deferred deint
                } else {
                    service_account.removeStorage(storage_key);
                }
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.FULL);
                return .play;
            } else {
                span.debug("Enough balance for storage", .{});
            }

            // Return the previous length per graypaper
            // DONE: (JAMDUNA) returns here 12
            // exec_ctx.registers[7] = value.len;
            // https://github.com/jam-duna/jamtestnet/issues/144
            // Wed 12 Mar 2025 17:11:17 CET Can be removed

            // This is GP
            exec_ctx.registers[7] = if (maybe_prior_value) |_|
                maybe_prior_value.?.len
            else
                @intFromEnum(ReturnCode.NONE);

            return .play;
        }

        /// Represents account information from a service
        pub const ServiceInfo = struct {
            /// Code hash of the service (tc)
            code_hash: [32]u8,
            /// Current balance of the service (tb)
            balance: types.Balance,
            /// Threshold balance required for the service (tt)
            threshold_balance: types.Balance,
            /// Gas limit for accumulator operations (tg)
            min_item_gas: types.Gas,
            /// Gas limit for on_transfer operations (tm)
            min_memo_gas: types.Gas,
            /// Total number of items in storage (ti)
            total_items: u32,
            /// Total storage size in bytes (tl)
            total_storage_size: u64,
        };

        /// Host call implementation for info service (Ω_I)
        pub fn infoService(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_info);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            // Get registers per graypaper B.7: service ID and output pointer
            const service_id = exec_ctx.registers[7];
            const output_ptr = exec_ctx.registers[8];

            span.debug("Host call: info for service {d}", .{service_id});
            span.debug("Output pointer: 0x{x}", .{output_ptr});

            // Get service account based on special cases as per graypaper
            const service_account = if (service_id == 0xFFFFFFFFFFFFFFFF) blk: {
                span.debug("Using current service ID: {d}", .{host_ctx.service_id});
                break :blk host_ctx.service_accounts.getReadOnly(host_ctx.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk host_ctx.service_accounts.getReadOnly(@intCast(service_id));
            };

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            }

            // Serialize service account info according to the graypaper
            span.debug("Service found, assembling info", .{});
            const fprint = service_account.?.storageFootprint();
            const service_info = ServiceInfo{
                .code_hash = service_account.?.code_hash,
                .balance = service_account.?.balance,
                .threshold_balance = fprint.a_t,
                .min_item_gas = service_account.?.min_gas_accumulate,
                .min_memo_gas = service_account.?.min_gas_on_transfer,
                .total_storage_size = fprint.a_o,
                .total_items = fprint.a_i,
            };

            var service_info_buffer: [@sizeOf(ServiceInfo)]u8 = undefined;
            var fb = std.io.fixedBufferStream(&service_info_buffer);

            // // FIXME: this is to conform to JamDuna format
            // // remove once fixed
            // fb.writer().writeByte(0x07) catch {};

            // Serialize
            @import("../codec.zig").serialize(
                ServiceInfo,
                .{},
                fb.writer(),
                service_info,
            ) catch {
                span.err("Problem serializing ServiceInfo", .{});
                return .{ .terminal = .panic };
            };

            // Write the info to memory
            const encoded = fb.getWritten();
            span.debug("Writing info encoded in {d} bytes to memory at 0x{x}", .{ encoded.len, output_ptr });
            span.trace("Encoded Info: {s}", .{std.fmt.fmtSliceHexLower(encoded)});
            exec_ctx.memory.writeSlice(@truncate(output_ptr), encoded) catch {
                span.err("Memory access failed while writing info data", .{});
                return .{ .terminal = .panic };
            };

            // Return success
            span.debug("Info request successful", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }
    };
}

/// GetChainConstants returns the encoded chain constants as per the JAM specification
fn encodeJamParams(allocator: std.mem.Allocator, params: Params) ![]u8 {
    // JAM Constants using GrayPaper notation - encoded in order per specification
    const EncodeMap = struct {
        BI: u64, // additional_minimum_balance_per_item
        BL: u64, // additional_minimum_balance_per_octet
        BS: u64, // basic_minimum_balance
        C: u16, // total_number_of_cores
        D: u32, // preimage_expulsion_period
        E: u32, // timeslots_per_epoch
        GA: u64, // max_allocated_gas_accumulation
        GI: u64, // max_allocated_gas_is_authorized
        GR: u64, // max_allocated_gas_refine
        GT: u64, // total_gas_accumulation
        H: u16, // max_recent_blocks
        I: u16, // max_number_of_items
        J: u16, // max_number_of_dependency_items
        L: u32, // max_timeslots_for_preimage
        O: u16, // max_authorizers_per_core
        P: u16, // slot_period_in_seconds
        Q: u16, // pending_authorizers_queue_size
        R: u16, // validator_rotation_period
        S: u16, // max_accumulation_queue_entries
        T: u16, // max_number_of_extrinsics
        U: u16, // work_report_timeout_period
        V: u16, // number_of_validators
        WA: u32, // maximum_size_is_authorized_code
        WB: u32, // max_work_package_size
        WC: u32, // max_size_service_code
        WE: u32, // erasure_coding_chunk_size
        WG: u32, // exported_segment_size
        WM: u32, // max_number_of_imports_exports
        WP: u32, // number_of_erasure_codec_pieces_in_segment
        WR: u32, // max_work_package_size_bytes
        WT: u32, // transfer_memo_size_bytes
        WX: u32, // max_number_of_exports
        Y: u32, // ticket_submission_time_slots
    };

    const constants = EncodeMap{
        .BI = params.min_balance_per_item,
        .BL = params.min_balance_per_octet,
        .BS = params.basic_service_balance,
        .C = params.core_count,
        .D = params.preimage_expungement_period,
        .E = params.epoch_length,
        .GA = params.gas_alloc_accumulation,
        .GI = params.gas_alloc_is_authorized,
        .GR = params.gas_alloc_refine,
        .GT = params.total_gas_alloc_accumulation,
        .H = params.recent_history_size,
        .I = params.max_work_items_per_package,
        .J = params.max_number_of_dependencies_for_work_reports,
        .L = params.max_lookup_anchor_age,
        .O = params.max_authorizations_pool_items,
        .P = params.slot_period,
        .Q = params.max_authorizations_queue_items,
        .R = @truncate(params.validator_rotation_period),
        .S = @truncate(params.max_accumulation_queue_entries),
        .T = params.max_extrinsics_per_work_package,
        .U = params.work_replacement_period,
        .V = @truncate(params.validators_count),
        .WA = params.max_authorization_code_size,
        .WB = params.max_work_package_size_with_extrinsics,
        .WC = params.max_service_code_size,
        .WE = params.erasure_coded_piece_size,
        .WG = params.exported_segment_size, // NOTE: WG now maps to exported_segment_size
        .WM = params.max_imports_per_work_package,
        .WP = params.exported_segment_size, // number_of_erasure_codec_pieces_in_segment
        .WR = params.max_work_report_size,
        .WT = params.transfer_memo_size,
        .WX = params.max_exports_per_work_package,
        .Y = params.ticket_submission_end_epoch_slot,
    };

    // Trace the constants being encoded
    const span = trace.span(.encode_jam_params);
    defer span.deinit();

    const codec = @import("../codec.zig");
    return try codec.serializeAlloc(EncodeMap, .{}, allocator, constants);
}
