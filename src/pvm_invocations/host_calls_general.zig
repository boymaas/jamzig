const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const ServiceAccount = @import("../services.zig").ServiceAccount;
const state_keys = @import("../state_keys.zig");
const PVM = @import("../pvm.zig").PVM;
const Params = @import("../jam_params.zig").Params;

const DeltaSnapshot = @import("../services_snapshot.zig").DeltaSnapshot;

const host_calls = @import("host_calls.zig");
const ReturnCode = host_calls.ReturnCode;
const HostCallError = host_calls.HostCallError;

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
    _ = params;
    return struct {
        // Removed deprecated InvocationContext

        /// Context for general host calls
        pub const Context = struct {
            /// The current service ID
            service_id: types.ServiceId,
            /// Reference to service accounts delta snapshot
            service_accounts: *DeltaSnapshot, // d ∈ D⟨N_S → A⟩
            /// Allocator for memory allocation
            allocator: std.mem.Allocator,
            // Removed deprecated invocation_context

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
                };
            }
        };

        // Encoding functions moved to specific host call implementations

        // Fetch function moved to specific host call implementations
        // (accumulate and ontransfer contexts have their own simplified versions)

        pub fn debugLog(
            exec_ctx: *PVM.ExecutionContext,
        ) HostCallError!PVM.HostCallResult {
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
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_gas);
            defer span.deinit();
            span.debug("Host call: gas remaining", .{});

            // Host call logging is now handled in hostcallInvocation with enhanced information
            // exec_ctx.exec_trace.logHostCall("gasRemaining", 1, 10);

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
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_lookup);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const service_id_reg = exec_ctx.registers[7];
            const hash_ptr = exec_ctx.registers[8];
            const output_ptr = exec_ctx.registers[9];
            const offset = exec_ctx.registers[10];
            const limit = exec_ctx.registers[11];

            span.debug("Host call: lookup preimage. Service: {d}, Hash ptr: 0x{x}, Output ptr: 0x{x}", .{
                service_id_reg, hash_ptr, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });

            // Resolve service ID using graypaper convention
            const resolved_service_id = host_calls.resolveTargetService(host_ctx, service_id_reg);

            // Get service account
            const service_account = host_ctx.service_accounts.getReadOnly(resolved_service_id);

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                return HostCallError.NONE;
            }

            // Read hash from memory (access verification is implicit)
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = try exec_ctx.readHash(@truncate(hash_ptr));

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Look up preimage at the specified timeslot
            span.debug("Looking up preimage", .{});
            const preimage_key = state_keys.constructServicePreimageKey(resolved_service_id, hash);
            const preimage = service_account.?.getPreimage(preimage_key) orelse {
                // Preimage not found, return error status
                span.debug("Preimage not found, returning NONE", .{});
                return HostCallError.NONE;
            };

            // Determine what to read from the preimage
            const f = @min(offset, preimage.len);
            const l = @min(limit, preimage.len - offset);
            span.debug("Preimage found, length: {d}, returning range {d}..{d} ({d} bytes)", .{
                preimage.len, f, f + l, l,
            });

            // Check if we're being asked for zero bytes (length query only)
            if (l == 0) {
                span.debug("Zero len requested, returning size: {d}", .{preimage.len});
                exec_ctx.registers[7] = preimage.len;
                return .play;
            }

            // Write length to memory first (this implicitly checks if the memory is writable)
            span.debug("Writing preimage to memory at 0x{x}", .{output_ptr});
            try exec_ctx.writeMemory(@truncate(output_ptr), preimage[f..][0..l]);

            // Success result
            exec_ctx.registers[7] = preimage.len; // Success status
            span.debug("Lookup successful, returning length: {d}", .{preimage.len});
            return .play;
        }

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx_: anytype,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_read);
            defer span.deinit();

            const host_ctx: Context = host_ctx_;
            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            // Get registers per graypaper B.7: (s*, k_o, k_z, o)
            const service_id_reg = exec_ctx.registers[7]; // Service ID (s*)
            const k_o = exec_ctx.registers[8]; // Key offset (k_o)
            const k_z = exec_ctx.registers[9]; // Key size (k_z)
            const output_ptr = exec_ctx.registers[10]; // Output buffer pointer (o)
            const offset = exec_ctx.registers[11]; // Offset in the value (f)
            const limit = exec_ctx.registers[12]; // Length limit (l)

            // Resolve service ID using graypaper convention
            const resolved_service_id = host_calls.resolveTargetService(host_ctx, service_id_reg);

            span.debug("Host call: read storage for service {d}", .{resolved_service_id});
            span.trace("Key ptr: 0x{x}, Key size: {d}, Output ptr: 0x{x}", .{
                k_o, k_z, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });

            // Get service account based on special cases as per graypaper B.7
            // s* = s when R7 = 2^64-1, otherwise s* = R7
            // a = s when s* = s, otherwise a = d[s*]
            const service_account = host_ctx.service_accounts.getReadOnly(resolved_service_id) orelse {
                span.debug("Service {d} not found, returning NONE", .{resolved_service_id});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            };

            // Read key data from memory
            span.debug("Reading key data from memory at 0x{x} (len={d})", .{ k_o, k_z });
            var key_data = try exec_ctx.readMemory(@truncate(k_o), @truncate(k_z));
            defer key_data.deinit();
            span.trace("Key = {s}", .{std.fmt.fmtSliceHexLower(key_data.buffer)});

            // Log the service ID and key for debugging
            span.info("Service ID for storage key: {d}", .{resolved_service_id});
            span.info("Raw key data (len={d}): {s}", .{ key_data.buffer.len, std.fmt.fmtSliceHexLower(key_data.buffer) });

            // Look up the value in storage using the new method
            span.debug("Looking up value in storage", .{});
            const value = service_account.readStorage(resolved_service_id, key_data.buffer) orelse {
                // Key not found
                span.debug("Key not found in storage, returning NONE", .{});
                return HostCallError.NONE;
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

            // Double check if we have any data to fetch
            const value_slice = value[f..][0..l];
            if (value_slice.len == 0) {
                span.debug("Zero len offset requested, returning size: {d}", .{value.len});
                exec_ctx.registers[7] = value.len;
                return .play;
            }

            // Write the value to memory
            span.debug("Writing value to memory at 0x{x}", .{output_ptr});
            try exec_ctx.writeMemory(@truncate(output_ptr), value_slice);

            // Success result
            exec_ctx.registers[7] = value.len;
            span.debug("Read successful, returning length: {d}", .{value.len});
            return .play;
        }

        /// Host call implementation for write storage (Ω_W)
        pub fn writeStorage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) HostCallError!PVM.HostCallResult {
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
            const service_account: *ServiceAccount = host_ctx.service_accounts.getMutable(host_ctx.service_id) catch {
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

            span.debug("Service ID for storage operation: {d}", .{host_ctx.service_id});
            span.info("Raw key data (len={d}): {s}", .{ key_data.buffer.len, std.fmt.fmtSliceHexLower(key_data.buffer) });

            // Check if this is a removal operation (v_z == 0)
            if (v_z == 0) {
                span.debug("Removal operation detected (v_z = 0)", .{});
                // Remove the key from storage
                if (service_account.removeStorage(host_ctx.service_id, key_data.buffer)) |value_length| {
                    exec_ctx.registers[7] = value_length;
                    return .play;
                }
                span.debug("Key not found, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            }

            // Read value from memory
            span.trace("Reading value data from memory at 0x{x} len={d}", .{ v_o, v_z });
            var value = try exec_ctx.readMemory(@truncate(v_o), @truncate(v_z));
            defer value.deinit();

            span.debug("Write operation - Key len={d}, Value len={d}", .{
                key_data.buffer.len,
                value.buffer.len,
            });
            span.trace("Value data: {s}", .{std.fmt.fmtSliceHexLower(value.buffer)});

            // In debug builds, also print as string if it looks like valid UTF-8
            if (std.debug.runtime_safety) {
                if (std.unicode.utf8ValidateSlice(value.buffer)) {
                    span.trace("Value as string: {s}", .{value.buffer});
                }
            }

            // Write and get the prior value owned
            var maybe_prior_value: ?[]const u8 = pv: {
                const value_owned = host_ctx.allocator.dupe(u8, value.buffer) catch {
                    return HostCallError.FULL;
                };
                break :pv service_account.writeStorage(host_ctx.service_id, key_data.buffer, value_owned) catch {
                    host_ctx.allocator.free(value_owned);
                    span.err("Failed to write to storage", .{});
                    return HostCallError.FULL;
                };
            };
            defer if (maybe_prior_value) |pv| host_ctx.allocator.free(pv);

            if (maybe_prior_value) |prior_value| {
                span.debug("Prior value found: {s}", .{std.fmt.fmtSliceHexLower(prior_value)});
            } else {
                span.debug("No prior value found", .{});
            }

            // Check if service has enough balance to store this data
            // REFACTOR: this can be simplified to first check if we alrady have a prior value
            // and actually determine the length and the delta
            const footprint = service_account.storageFootprint();
            span.debug("Checking storage footprint a_t {d} against balance {d}", .{ footprint.a_t, service_account.balance });
            if (footprint.a_t > service_account.balance) {
                span.warn("Insufficient balance for storage, returning FULL", .{});
                // Restore old value, if we had a prior value, otherwise
                // we remove the storage key, as we do not have enough balance
                if (maybe_prior_value) |prior_value| {
                    service_account.writeStorageFreeOldValue(host_ctx.service_id, key_data.buffer, prior_value) catch {
                        return HostCallError.FULL;
                    };
                    maybe_prior_value = null; // to avoid deferred deint
                } else {
                    _ = service_account.removeStorage(host_ctx.service_id, key_data.buffer);
                }
                return HostCallError.FULL;
            } else {
                span.debug("Enough balance for storage", .{});
            }

            // This is GP
            exec_ctx.registers[7] = if (maybe_prior_value) |_|
                maybe_prior_value.?.len
            else
                @intFromEnum(ReturnCode.NONE);

            return .play;
        }

        /// Represents account information from a service
        pub const ServiceInfo = struct {
            /// Code hash of the service (a_c)
            code_hash: [32]u8,
            /// Current balance of the service (a_b)
            balance: types.Balance,
            /// Threshold balance required for the service (a_t)
            threshold_balance: types.Balance,
            /// Gas limit for accumulator operations (a_g)
            min_item_gas: types.Gas,
            /// Gas limit for on_transfer operations (a_m)
            min_memo_gas: types.Gas,
            /// Total storage size in bytes (a_o - includes both storage and preimages)
            total_storage_size: u64,
            /// Total number of items in storage (a_i - includes both storage and preimage lookups)
            total_items: u32,
            /// Free storage offset (a_f)
            free_storage_offset: u64,
            /// Time slot at creation (a_r)
            creation_slot: u32,
            /// Time slot at most recent accumulation (a_a)
            last_accumulation_slot: u32,
            /// Parent service ID (a_p)
            parent_service: u32,

            pub fn encode(
                self: ServiceInfo,
                writer: anytype,
            ) !void {
                // se(a_c, se_8(a_b, a_t, a_g, a_m, a_o), se_4(a_i), se_8(a_f), se_4(a_r, a_a, a_p))

                // Write code hash (32 bytes)
                try writer.writeAll(&self.code_hash);

                // Write first group of 8-byte values: a_b, a_t, a_g, a_m, a_o
                try writer.writeInt(u64, self.balance, .little);
                try writer.writeInt(u64, self.threshold_balance, .little);
                try writer.writeInt(u64, self.min_item_gas, .little);
                try writer.writeInt(u64, self.min_memo_gas, .little);
                try writer.writeInt(u64, self.total_storage_size, .little);

                // Write a_i as 4-byte value
                try writer.writeInt(u32, self.total_items, .little);

                // Write a_f as 8-byte value
                try writer.writeInt(u64, self.free_storage_offset, .little);

                // Write last group of 4-byte values: a_r, a_a, a_p
                try writer.writeInt(u32, self.creation_slot, .little);
                try writer.writeInt(u32, self.last_accumulation_slot, .little);
                try writer.writeInt(u32, self.parent_service, .little);
            }
        };

        /// Host call implementation for info service (Ω_I)
        pub fn infoService(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx_: anytype,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_info);
            defer span.deinit();

            const host_ctx: Context = host_ctx_;

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            // Get registers per graypaper B.7: service ID, output pointer, offset, and limit
            const service_id_reg = exec_ctx.registers[7];
            const output_ptr = exec_ctx.registers[8];
            const offset = exec_ctx.registers[9]; // This was a typo in the graypaper 0.6.7
            const limit = exec_ctx.registers[10];

            // Resolve service ID using graypaper convention
            const resolved_service_id = host_calls.resolveTargetService(host_ctx, service_id_reg);

            span.debug("Host call: info for service {d}", .{resolved_service_id});
            span.debug("Output pointer: 0x{x}, Offset: {d}, Limit: {d}", .{ output_ptr, offset, limit });

            // Get service account
            const service_account = host_ctx.service_accounts.getReadOnly(resolved_service_id);

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                return HostCallError.NONE;
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
                .free_storage_offset = service_account.?.storage_offset,
                // Graypaper-compliant fields: a_r, a_a, a_p
                .creation_slot = service_account.?.creation_slot,
                .last_accumulation_slot = service_account.?.last_accumulation_slot,
                .parent_service = service_account.?.parent_service,
            };

            // Since we are varint encoding will only be smaller
            var service_info_buffer: [@sizeOf(ServiceInfo)]u8 = undefined;
            var fb = std.io.fixedBufferStream(&service_info_buffer);

            service_info.encode(fb.writer()) catch {
                span.err("Problem encoding ServiceInfo", .{});
                return HostCallError.FULL;
            };
            const encoded = fb.getWritten();

            // Calculate offset and limit for partial reading (graypaper formula)
            const f = @min(offset, encoded.len);
            const l = @min(limit, encoded.len - f);

            span.debug("Encoded info length: {d}, returning range {d}..{d} ({d} bytes)", .{
                encoded.len, f, f + l, l,
            });

            // Check if we're being asked for zero bytes (length query only)
            if (l == 0) {
                span.debug("Zero len requested, returning size: {d}", .{encoded.len});
                exec_ctx.registers[7] = encoded.len;
                return .play;
            }

            // Write the partial info to memory
            span.debug("Writing {d} bytes to memory at 0x{x}", .{ l, output_ptr });
            span.trace("Encoded Info slice: {s}", .{std.fmt.fmtSliceHexLower(encoded[f..][0..l])});
            try exec_ctx.writeMemory(@truncate(output_ptr), encoded[f..][0..l]);

            // Return the total encoded length (not just what was written)
            span.debug("Info request successful, returning total length: {d}", .{encoded.len});
            exec_ctx.registers[7] = encoded.len;
            return .play;
        }
    };
}

// JAM parameters encoding moved to specific host call implementations
