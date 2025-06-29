const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
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
                // Available in accumulation context
                validator_keys: ?*const state.Iota = null,
                authorizer_queue: ?*const state.Phi(params.core_count, params.max_authorizations_queue_items) = null,
                privileges: ?*const state.Chi = null,
                time: ?*const params.Time() = null,
                // Enhanced data for fetch selectors
                entropy: ?types.Entropy = null,
                authorizer_hash_output: ?Hash256 = null,
                outputs: ?[]const types.AccumulateOutput = null,
                transfers: ?[]const @import("accumulate/types.zig").DeferredTransfer = null,
            };

            pub const OnTransferData = struct {
                // Limited data available in transfer context
                // Could include transfer-specific information
                transfer_memo: ?[]const u8 = null,
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

        /// Host call implementation for fetch (Ω_Y)
        ///
        /// Implements fetch selectors as specified in JAM graypaper §1.7.2:
        /// - Selector 0: JAM chain constants (IMPLEMENTED - returns encoded parameters)
        /// - Selectors 1-2: Block/state data (accumulate context only)
        /// - Selectors 3-13: REMOVED FOR REFINE (work package specific selectors)
        /// - Selector 14: REMOVED FOR REFINE (operands)
        /// - Selectors 15-16: Transfers (accumulate context only)
        /// - Selector 17: Outputs (accumulate context only)
        ///
        /// General host calls context supports selector 0. Accumulate context supports
        /// selectors 1-2, 15-17. Refine-specific selectors (3-14) have been removed.
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
                            .accumulate => |acc_data| {
                                if (acc_data.entropy) |entropy| {
                                    span.debug("Entropy available from accumulate context", .{});
                                    data_to_fetch = entropy[0..];
                                } else {
                                    span.debug("Entropy not set in accumulate context", .{});
                                }
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
                    // Selector 2: Authorizer hash output (ω) - available in accumulate context
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            // REMOVED FOR REFINE: .refine case
                            .accumulate => |acc_data| {
                                if (acc_data.authorizer_hash_output) |hash_output| {
                                    span.debug("Authorizer hash output available from accumulate context", .{});
                                    data_to_fetch = hash_output[0..];
                                } else {
                                    span.debug("Authorizer hash output not set in accumulate context", .{});
                                }
                            },
                            else => {
                                span.debug("Authorizer hash output not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Authorizer hash output fetch: no invocation context available", .{});
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
                3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 => {
                    span.debug("Selector {d} disabled (refine-only)", .{selector});
                    exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                    return .play;
                },

                15 => {
                    // Selector 15: Encoded transfers
                    // E(transfers)
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            // REMOVED FOR REFINE: .refine case
                            .accumulate => |acc_data| {
                                if (acc_data.transfers) |transfers| {
                                    // Encode transfers array
                                    const transfers_data = encodeTransfers(host_ctx.allocator, transfers) catch {
                                        span.err("Failed to encode transfers", .{});
                                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                        return .play;
                                    };
                                    span.debug("Transfers encoded successfully from accumulate context, count={d}", .{transfers.len});
                                    data_to_fetch = transfers_data;
                                    needs_cleanup = true;
                                } else {
                                    span.debug("Transfers not available in accumulate context", .{});
                                }
                            },
                            else => {
                                span.debug("Transfers not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Transfers fetch: no invocation context available", .{});
                    }

                    if (data_to_fetch == null) {
                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                        return .play;
                    }
                },

                16 => {
                    // Selector 16: Specific transfer
                    // E(transfers[registers[11]])
                    const transfer_index = @as(u32, @intCast(exec_ctx.registers[11]));

                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            // REMOVED FOR REFINE: .refine case
                            .accumulate => |acc_data| {
                                if (acc_data.transfers) |transfers| {
                                    if (transfer_index < transfers.len) {
                                        const transfer = &transfers[transfer_index];
                                        const transfer_data = encodeTransfer(host_ctx.allocator, transfer) catch {
                                            span.err("Failed to encode transfer", .{});
                                            exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                            return .play;
                                        };
                                        span.debug("Transfer encoded successfully from accumulate context: index={d}", .{transfer_index});
                                        data_to_fetch = transfer_data;
                                        needs_cleanup = true;
                                    } else {
                                        span.debug("Transfer index out of bounds in accumulate context: index={d}, count={d}", .{ transfer_index, transfers.len });
                                    }
                                } else {
                                    span.debug("Transfers not available in accumulate context", .{});
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

                17 => {
                    // Selector 17: Outputs (accumulation results)
                    // E(outputs)
                    if (host_ctx.invocation_context) |ctx| {
                        switch (ctx) {
                            .accumulate => |acc_data| {
                                if (acc_data.outputs) |outputs| {
                                    // Encode outputs array
                                    const outputs_data = encodeOutputs(host_ctx.allocator, outputs) catch {
                                        span.err("Failed to encode outputs", .{});
                                        exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                                        return .play;
                                    };
                                    span.debug("Outputs encoded successfully, count={d}", .{outputs.len});
                                    data_to_fetch = outputs_data;
                                    needs_cleanup = true;
                                } else {
                                    span.debug("Outputs not available in accumulate context", .{});
                                }
                            },
                            else => {
                                span.debug("Outputs not available in {s} context", .{@tagName(ctx)});
                            },
                        }
                    } else {
                        span.debug("Outputs fetch: no invocation context available", .{});
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
            const preimage = service_account.?.getPreimage(hash) orelse {
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

            // Construct storage key: H(E_4(service_id) ⌢ key_data)
            span.debug("Constructing storage key", .{});
            var key_input = std.ArrayList(u8).init(host_ctx.allocator);
            defer key_input.deinit();

            // Add service ID as bytes (4 bytes in little-endian)
            var service_id_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &service_id_bytes, if (service_id == 0xFFFFFFFFFFFFFFFF) host_ctx.service_id else @intCast(service_id), .little);
            key_input.appendSlice(&service_id_bytes) catch {
                span.err("Failed to append service ID to key input", .{});
                return .{ .terminal = .panic };
            };

            // Add key data
            key_input.appendSlice(key_data.buffer) catch {
                span.err("Failed to append key data to key input", .{});
                return .{ .terminal = .panic };
            };

            // Hash to get final storage key
            var storage_key: [32]u8 = undefined;
            // FIXME: we can hash without allocation
            std.crypto.hash.blake2.Blake2b256.hash(key_input.items, &storage_key, .{});
            span.trace("Generated storage key: {s}", .{std.fmt.fmtSliceHexLower(&storage_key)});

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
            key_input.appendSlice(key_data.buffer) catch {
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
    const EncodeMap = struct {
        additional_minimum_balance_per_item: u64, // BI
        additional_minimum_balance_per_octet: u64, // BL
        basic_minimum_balance: u64, // BS
        total_number_of_cores: u16, // C
        preimage_expulsion_period: u32, // D
        timeslots_per_epoch: u32, // E
        max_allocated_gas_accumulation: u64, // GA
        max_allocated_gas_is_authorized: u64, // GI
        max_allocated_gas_refine: u64, // GR
        total_gas_accumulation: u64, // GT
        max_recent_blocks: u16, // H
        max_number_of_items: u16, // I
        max_number_of_dependency_items: u16, // J
        max_tickets_per_block: u16, // K
        max_timeslots_for_preimage: u32, // L
        max_ticket_attempts_per_validator: u16, // N
        max_authorizers_per_core: u16, // O
        slot_period_in_seconds: u16, // P
        pending_authorizers_queue_size: u16, // Q
        validator_rotation_period: u16, // R
        max_accumulation_queue_entries: u16, // S
        max_number_of_extrinsics: u16, // T
        work_report_timeout_period: u16, // U
        number_of_validators: u16, // V
        maximum_size_is_authorized_code: u32, // WA
        max_work_package_size: u32, // WB
        max_size_service_code: u32, // WC
        erasure_coding_chunk_size: u32, // WE
        max_number_of_imports_exports: u32, // WM
        number_of_erasure_codec_pieces_in_segment: u32, // WP
        max_work_package_size_bytes: u32, // WR
        transfer_memo_size_bytes: u32, // WT
        max_number_of_exports: u32, // WX
        ticket_submission_time_slots: u32, // Y
    };

    const constants = EncodeMap{
        .additional_minimum_balance_per_item = params.min_balance_per_item,
        .additional_minimum_balance_per_octet = params.min_balance_per_octet,
        .basic_minimum_balance = params.basic_service_balance,
        .total_number_of_cores = params.core_count,
        .preimage_expulsion_period = params.preimage_expungement_period,
        .timeslots_per_epoch = params.epoch_length,
        .max_allocated_gas_accumulation = params.gas_alloc_accumulation,
        .max_allocated_gas_is_authorized = params.gas_alloc_is_authorized,
        .max_allocated_gas_refine = params.gas_alloc_refine,
        .total_gas_accumulation = params.total_gas_alloc_accumulation,
        .max_recent_blocks = params.recent_history_size,
        .max_number_of_items = params.max_work_items_per_package,
        .max_number_of_dependency_items = params.max_number_of_dependencies_for_work_reports,
        .max_tickets_per_block = @truncate(params.max_tickets_per_extrinsic),
        .max_timeslots_for_preimage = params.max_lookup_anchor_age,
        .max_ticket_attempts_per_validator = params.max_ticket_entries_per_validator,
        .max_authorizers_per_core = params.max_authorizations_pool_items,
        .slot_period_in_seconds = params.slot_period,
        .pending_authorizers_queue_size = params.max_authorizations_queue_items,
        .validator_rotation_period = @truncate(params.validator_rotation_period),
        .max_accumulation_queue_entries = @truncate(params.max_accumulation_queue_entries),
        .max_number_of_extrinsics = @truncate(params.max_tickets_per_extrinsic), // T - derived from K (max tickets per extrinsic)
        .work_report_timeout_period = params.work_replacement_period,
        .number_of_validators = @truncate(params.validators_count),
        .maximum_size_is_authorized_code = params.max_authorization_code_size,
        .max_work_package_size = params.max_work_package_size,
        .max_size_service_code = params.max_service_code_size,
        .erasure_coding_chunk_size = params.erasure_coded_piece_size,
        .max_number_of_imports_exports = params.max_manifest_entries,
        .number_of_erasure_codec_pieces_in_segment = params.exported_segment_size,
        .max_work_package_size_bytes = params.max_work_report_size,
        .transfer_memo_size_bytes = params.transfer_memo_size,
        .max_number_of_exports = params.max_manifest_entries, // WX - derived from WM (max manifest entries)
        .ticket_submission_time_slots = params.ticket_submission_end_epoch_slot,
    };

    // Trace the constants being encoded
    const span = trace.span(.encode_jam_params);
    defer span.deinit();

    span.debug("Encoding JAM parameters:", .{});
    span.debug("  Cores: {d}, Validators: {d}, Epoch length: {d}", .{
        constants.total_number_of_cores,
        constants.number_of_validators,
        constants.timeslots_per_epoch,
    });
    span.debug("  Gas allocations - Accumulation: {d}, Refine: {d}, Total: {d}", .{
        constants.max_allocated_gas_accumulation,
        constants.max_allocated_gas_refine,
        constants.total_gas_accumulation,
    });
    span.debug("  Balances - Basic: {d}, Per item: {d}, Per octet: {d}", .{
        constants.basic_minimum_balance,
        constants.additional_minimum_balance_per_item,
        constants.additional_minimum_balance_per_octet,
    });

    const codec = @import("../codec.zig");
    return try codec.serializeAlloc(EncodeMap, .{}, allocator, constants);
}
