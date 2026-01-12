
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

const trace = @import("tracing").scoped(.host_calls);

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

        /// Context for general host calls
        pub const Context = struct {
            /// The current service ID
            service_id: types.ServiceId,
            /// Reference to service accounts delta snapshot
            service_accounts: *DeltaSnapshot, // d ∈ D⟨N_S → A⟩
            /// Allocator for memory allocation
            allocator: std.mem.Allocator,

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



        pub fn debugLog(
            exec_ctx: *PVM.ExecutionContext,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_debug_log);
            defer span.deinit();

            // JIP-1: https://github.com/polkadot-fellows/JIPs/blob/main/JIP-1.md
            // Gas cost: 10 units
            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

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
                exec_ctx.registers[7] = @intFromEnum(host_calls.ReturnCode.WHAT);
                return .play;
            };
            defer message.deinit();

            span.warn("DEBUGLOG {s} {s}: {s}", .{ level, target.buffer, message.buffer });

            exec_ctx.registers[7] = @intFromEnum(host_calls.ReturnCode.WHAT);
            return .play;
        }

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_gas);
            defer span.deinit();
            span.debug("Host call: gas remaining", .{});


            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

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
            const span = trace.span(@src(), .host_call_lookup);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const service_id_reg = exec_ctx.registers[7];
            const hash_ptr = exec_ctx.registers[8];
            const output_ptr = exec_ctx.registers[9];
            const offset = exec_ctx.registers[10];
            const limit = exec_ctx.registers[11];

            span.debug("Host call: lookup preimage. Service: {d}, Hash ptr: 0x{x}, Output ptr: 0x{x}", .{
                service_id_reg, hash_ptr, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });


            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = try exec_ctx.readHash(@truncate(hash_ptr));
            span.debug("Preimage hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            const resolved_service_id = host_calls.resolveTargetService(host_ctx, service_id_reg);
            span.trace("Resolved service ID: {d}", .{resolved_service_id});

            const service_account: ?*const ServiceAccount = host_ctx.service_accounts.getReadOnly(resolved_service_id);

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                return HostCallError.NONE;
            }

            span.debug("Looking up preimage", .{});
            const preimage_key = state_keys.constructServicePreimageKey(resolved_service_id, hash);
            const preimage = service_account.?.getPreimage(preimage_key) orelse {
                span.debug("Preimage not found, returning NONE", .{});
                return HostCallError.NONE;
            };

            const f = @min(offset, preimage.len);
            const l = @min(limit, preimage.len - f); // Use f not offset per graypaper
            span.debug("Preimage found, length: {d}, returning range {d}..{d} ({d} bytes)", .{
                preimage.len, f, f + l, l,
            });

            if (l == 0) {
                span.debug("Zero len requested, returning size: {d}", .{preimage.len});
                exec_ctx.registers[7] = preimage.len;
                return .play;
            }

            span.debug("Writing preimage to memory at 0x{x}", .{output_ptr});
            try exec_ctx.writeMemory(@truncate(output_ptr), preimage[f..][0..l]);

            exec_ctx.registers[7] = preimage.len; // Success status
            span.debug("Lookup successful, returning length: {d}", .{preimage.len});
            return .play;
        }

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx_: anytype,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_read);
            defer span.deinit();

            const host_ctx: Context = host_ctx_;
            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const service_id_reg = exec_ctx.registers[7]; // Service ID (s*)
            const k_o = exec_ctx.registers[8]; // Key offset (k_o)
            const k_z = exec_ctx.registers[9]; // Key size (k_z)
            const output_ptr = exec_ctx.registers[10]; // Output buffer pointer (o)
            const offset = exec_ctx.registers[11]; // Offset in the value (f)
            const limit = exec_ctx.registers[12]; // Length limit (l)

            const resolved_service_id = host_calls.resolveTargetService(host_ctx, service_id_reg);

            span.debug("Host call: read storage for service {d}", .{resolved_service_id});
            span.trace("Key ptr: 0x{x}, Key size: {d}, Output ptr: 0x{x}", .{
                k_o, k_z, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });

            span.debug("Reading key data from memory at 0x{x} (len={d})", .{ k_o, k_z });
            var key_data = try exec_ctx.readMemory(@truncate(k_o), @truncate(k_z));
            defer key_data.deinit();

            const service_account = host_ctx.service_accounts.getReadOnly(resolved_service_id) orelse {
                span.debug("Service {d} not found, returning NONE", .{resolved_service_id});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            };
            span.trace("Key = {s}", .{std.fmt.fmtSliceHexLower(key_data.buffer)});

            span.info("Service ID for storage key: {d}", .{resolved_service_id});
            span.info("Raw key data (len={d}): {s}", .{ key_data.buffer.len, std.fmt.fmtSliceHexLower(key_data.buffer) });

            span.debug("Looking up value in storage", .{});
            const value = service_account.readStorage(resolved_service_id, key_data.buffer) orelse {
                span.debug("Key not found in storage, returning NONE", .{});
                return HostCallError.NONE;
            };

            const f = @min(offset, value.len);
            const l = @min(limit, value.len - f);
            span.debug("Value found, length: {d}, returning range {d}..{d} ({d} bytes) => {s}", .{
                value.len,
                f,
                f + l,
                l,
                std.fmt.fmtSliceHexLower(value[f..][0..l]),
            });

            const value_slice = value[f..][0..l];
            if (value_slice.len == 0) {
                span.debug("Zero len offset requested, returning size: {d}", .{value.len});
                exec_ctx.registers[7] = value.len;
                return .play;
            }

            span.debug("Writing value to memory at 0x{x}", .{output_ptr});
            try exec_ctx.writeMemory(@truncate(output_ptr), value_slice);

            exec_ctx.registers[7] = value.len;
            span.debug("Read successful, returning length: {d}", .{value.len});
            return .play;
        }

        /// Host call implementation for write storage (Ω_W)
        /// Follows graypaper approach: check balance BEFORE modifying state
        pub fn writeStorage(
            exec_ctx: *PVM.ExecutionContext,
            host_ctx: anytype,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_write);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const k_o = exec_ctx.registers[7]; // Key offset
            const k_z = exec_ctx.registers[8]; // Key size
            const v_o = exec_ctx.registers[9]; // Value offset
            const v_z = exec_ctx.registers[10]; // Value size

            span.debug("Host call: write storage for service {d}", .{host_ctx.service_id});
            span.trace("Key ptr: 0x{x}, Key size: {d}, Value ptr: 0x{x}, Value size: {d}", .{
                k_o, k_z, v_o, v_z,
            });

            span.debug("Looking up service account", .{});
            const service_account: *ServiceAccount = host_ctx.service_accounts.getMutable(host_ctx.service_id) catch {
                span.err("Could not create mutable instance of service accounts", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Reading key data from memory at 0x{x} (len={d})", .{ k_o, k_z });
            var key_data = exec_ctx.memory.readSlice(@truncate(k_o), @truncate(k_z)) catch {
                span.err("Memory access failed while reading key data", .{});
                return .{ .terminal = .panic };
            };
            defer key_data.deinit();
            span.trace("Key data: {s}", .{std.fmt.fmtSliceHexLower(key_data.buffer)});

            span.debug("Service ID for storage operation: {d}", .{host_ctx.service_id});
            span.info("Raw key data (len={d}): {s}", .{ key_data.buffer.len, std.fmt.fmtSliceHexLower(key_data.buffer) });

            if (v_z == 0) {
                span.debug("Removal operation detected (v_z = 0)", .{});
                if (service_account.removeStorage(host_ctx.service_id, key_data.buffer)) |value_length| {
                    span.debug("Key removed successfully, prior value length: {d}", .{value_length});
                    exec_ctx.registers[7] = value_length;
                    return .play;
                }
                span.debug("Key not found, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.NONE);
                return .play;
            }

            span.trace("Reading value data from memory at 0x{x} len={d}", .{ v_o, v_z });
            var value = try exec_ctx.readMemory(@truncate(v_o), @truncate(v_z));
            defer value.deinit();

            span.debug("Write operation - Key len={d}, Value len={d}", .{
                key_data.buffer.len,
                value.buffer.len,
            });
            span.trace("Value data: {s}", .{std.fmt.fmtSliceHexLower(value.buffer)});

            if (std.debug.runtime_safety) {
                if (std.unicode.utf8ValidateSlice(value.buffer)) {
                    span.trace("Value as string: {s}", .{value.buffer});
                }
            }

            const analysis = service_account.analyzeStorageWrite(
                params,
                host_ctx.service_id,
                key_data.buffer,
                value.buffer.len,
            );

            span.debug("Checking if operation is affordable: new a_t={d} vs balance={d}", .{
                analysis.new_footprint.a_t,
                service_account.balance,
            });

            if (analysis.new_footprint.a_t > service_account.balance) {
                span.warn("Insufficient balance for storage operation, returning FULL without modifying state", .{});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.FULL);
                return .play;
            }

            span.debug("Balance check passed, proceeding with write operation", .{});

            const value_owned = value.takeBufferOwnership(host_ctx.allocator) catch {
                span.err("Failed to allocate memory for value", .{});
                return .{ .terminal = .panic }; // Memory allocation failure should panic
            };
            errdefer host_ctx.allocator.free(value_owned); // Clean up on any error

            service_account.writeStorageFreeOldValue(host_ctx.service_id, key_data.buffer, value_owned) catch {
                span.err("Failed to write to storage", .{});
                return .{ .terminal = .panic }; // Panic on write failure
            };

            if (analysis.prior_value) |_| {
                span.debug("Replaced existing value", .{});
            } else {
                span.debug("Wrote new key", .{});
            }

            exec_ctx.registers[7] = analysis.prior_value_length;
            span.debug("Write successful, returning prior value length: {d}", .{analysis.prior_value_length});

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

                try writer.writeAll(&self.code_hash);

                try writer.writeInt(u64, self.balance, .little);
                try writer.writeInt(u64, self.threshold_balance, .little);
                try writer.writeInt(u64, self.min_item_gas, .little);
                try writer.writeInt(u64, self.min_memo_gas, .little);
                try writer.writeInt(u64, self.total_storage_size, .little);

                try writer.writeInt(u32, self.total_items, .little);

                try writer.writeInt(u64, self.free_storage_offset, .little);

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
            const span = trace.span(@src(), .host_call_info);
            defer span.deinit();

            const host_ctx: Context = host_ctx_;

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const service_id_reg = exec_ctx.registers[7];
            const output_ptr = exec_ctx.registers[8];
            const offset = exec_ctx.registers[9]; // This was a typo in the graypaper 0.6.7
            const limit = exec_ctx.registers[10];

            const resolved_service_id = host_calls.resolveTargetService(host_ctx, service_id_reg);

            span.debug("Host call: info for service {d}", .{resolved_service_id});
            span.debug("Output pointer: 0x{x}, Offset: {d}, Limit: {d}", .{ output_ptr, offset, limit });

            const service_account = host_ctx.service_accounts.getReadOnly(resolved_service_id);

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                return HostCallError.NONE;
            }

            span.debug("Service found, assembling info", .{});
            const fprint = service_account.?.getStorageFootprint(params);
            const service_info = ServiceInfo{
                .code_hash = service_account.?.code_hash,
                .balance = service_account.?.balance,
                .threshold_balance = fprint.a_t,
                .min_item_gas = service_account.?.min_gas_accumulate,
                .min_memo_gas = service_account.?.min_gas_on_transfer,
                .total_storage_size = fprint.a_o,
                .total_items = fprint.a_i,
                .free_storage_offset = service_account.?.storage_offset,
                .creation_slot = service_account.?.creation_slot,
                .last_accumulation_slot = service_account.?.last_accumulation_slot,
                .parent_service = service_account.?.parent_service,
            };

            var service_info_buffer: [@sizeOf(ServiceInfo)]u8 = undefined;
            var fb = std.io.fixedBufferStream(&service_info_buffer);

            service_info.encode(fb.writer()) catch {
                span.err("Problem encoding ServiceInfo", .{});
                return HostCallError.FULL;
            };
            const encoded = fb.getWritten();

            const f = @min(offset, encoded.len);
            const l = @min(limit, encoded.len - f);

            span.debug("Encoded info length: {d}, returning range {d}..{d} ({d} bytes)", .{
                encoded.len, f, f + l, l,
            });

            if (l == 0) {
                span.debug("Zero len requested, returning size: {d}", .{encoded.len});
                exec_ctx.registers[7] = encoded.len;
                return .play;
            }

            span.debug("Writing {d} bytes to memory at 0x{x}", .{ l, output_ptr });
            span.trace("Encoded Info slice: {s}", .{std.fmt.fmtSliceHexLower(encoded[f..][0..l])});
            try exec_ctx.writeMemory(@truncate(output_ptr), encoded[f..][0..l]);

            span.debug("Info request successful, returning total length: {d}", .{encoded.len});
            exec_ctx.registers[7] = encoded.len;
            return .play;
        }
    };
}

