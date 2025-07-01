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
        /// Optional invocation-specific context (kept for compatibility with existing functions)
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
            /// Optional invocation-specific context (kept for compatibility with existing functions)
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

        // Encoding functions moved to specific host call implementations

        // Fetch function moved to specific host call implementations
        // (accumulate and ontransfer contexts have their own simplified versions)

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

// JAM parameters encoding moved to specific host call implementations
