const std = @import("std");
const types = @import("../../types.zig");

const service_util = @import("service_util.zig");
const DeferredTransfer = @import("types.zig").DeferredTransfer;
const AccumulationContext = @import("context.zig").AccumulationContext;
const Params = @import("../../jam_params.zig").Params;

const PVM = @import("../../pvm.zig").PVM;

// Add tracing import
const trace = @import("../../tracing.zig").scoped(.accumulate);

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

pub fn HostCalls(params: Params) type {
    return struct {
        pub const Context = struct {
            regular: Dimension,
            exceptional: Dimension,

            pub fn constructUsingRegular(regular: Dimension) !Context {
                return .{
                    .regular = regular,
                    .exceptional = try regular.deepClone(),
                };
            }

            pub fn deinit(self: *Context) void {
                self.regular.deinit();
                self.exceptional.deinit();
                self.* = undefined;
            }
        };

        /// Context maintained during host call execution
        pub const Dimension = struct {
            allocator: std.mem.Allocator,
            context: AccumulationContext(params),
            service_id: types.ServiceId,
            new_service_id: types.ServiceId,
            deferred_transfers: std.ArrayList(DeferredTransfer),
            accumulation_output: ?types.AccumulateRoot,

            pub fn commit(self: *@This()) !void {
                try self.context.commit();
            }

            pub fn deepClone(self: *const @This()) !@This() {
                // Create a new context with the same allocator
                const new_context = @This(){
                    .allocator = self.allocator,
                    .context = try self.context.deepClone(),
                    .service_id = self.service_id,
                    .new_service_id = self.new_service_id,
                    .deferred_transfers = try self.deferred_transfers.clone(),
                    .accumulation_output = self.accumulation_output,
                };

                return new_context;
            }

            pub fn deinit(self: *@This()) void {
                self.deferred_transfers.deinit();
                self.context.deinit();
                self.* = undefined;
            }
        };

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_gas);
            defer span.deinit();
            span.debug("Host call: gas remaining", .{});

            _ = call_ctx;

            exec_ctx.gas -= 10;
            const remaining_gas = exec_ctx.gas;
            exec_ctx.registers[7] = @intCast(remaining_gas);

            span.debug("Remaining gas: {d}", .{remaining_gas});
            return .play;
        }

        /// Host call implementation for lookup preimage (Ω_L)
        pub fn lookupPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_lookup);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular = host_ctx.regular;
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
            const service_account = if (service_id == ctx_regular.service_id or service_id == 0xFFFFFFFFFFFFFFFF) blk: {
                span.debug("Using current service ID: {d}", .{ctx_regular.service_id});
                break :blk ctx_regular.context.service_accounts.getReadOnly(ctx_regular.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk ctx_regular.context.service_accounts.getReadOnly(@intCast(service_id));
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

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_read);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular = host_ctx.regular;

            // Get registers per graypaper B.7: (s*, k_o, k_z, o)
            const service_id = exec_ctx.registers[7]; // Service ID (s*)
            const k_o = exec_ctx.registers[8]; // Key offset (k_o)
            const k_z = exec_ctx.registers[9]; // Key size (k_z)
            const output_ptr = exec_ctx.registers[10]; // Output buffer pointer (o)
            const offset = exec_ctx.registers[11]; // Offset in the value (f)
            const limit = exec_ctx.registers[12]; // Length limit (l)

            span.debug("Host call: read storage for service {d}", .{service_id});
            span.debug("Key ptr: 0x{x}, Key size: {d}, Output ptr: 0x{x}", .{
                k_o, k_z, output_ptr,
            });
            span.debug("Offset: {d}, Limit: {d}", .{ offset, limit });

            // Get service account based on special cases as per graypaper B.7
            const service_account = if (service_id == 0xFFFFFFFFFFFFFFFF) blk: {
                span.debug("Using current service ID: {d}", .{ctx_regular.service_id});
                break :blk ctx_regular.context.service_accounts.getReadOnly(ctx_regular.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk ctx_regular.context.service_accounts.getReadOnly(@intCast(service_id));
            };

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE);
                return .play;
            }

            // Read key data from memory
            span.debug("Reading key data from memory at 0x{x} (len={d})", .{ k_o, k_z });
            const key_data = exec_ctx.memory.readSlice(@truncate(k_o), @truncate(k_z)) catch {
                span.err("Memory access failed while reading key data", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Key data: {s}", .{std.fmt.fmtSliceHexLower(key_data)});

            // Construct storage key: H(E_4(service_id) ⌢ key_data)
            span.debug("Constructing storage key", .{});
            var key_input = std.ArrayList(u8).init(ctx_regular.allocator);
            defer key_input.deinit();

            // Add service ID as bytes (4 bytes in little-endian)
            var service_id_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &service_id_bytes, if (service_id == 0xFFFFFFFFFFFFFFFF) ctx_regular.service_id else @intCast(service_id), .little);
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

            // Look up the value in storage
            span.debug("Looking up value in storage", .{});
            const value = service_account.?.storage.get(storage_key) orelse {
                // Key not found
                span.debug("Key not found in storage, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE);
                return .play;
            };

            // Determine what to read from the value
            const f = @min(offset, value.len);
            const l = @min(limit, value.len - f);
            span.debug("Value found, length: {d}, returning range {d}..{d} ({d} bytes)", .{
                value.len, f, f + l, l,
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
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_write);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: (k_o, k_z, v_o, v_z)
            const k_o = exec_ctx.registers[7]; // Key offset
            const k_z = exec_ctx.registers[8]; // Key size
            const v_o = exec_ctx.registers[9]; // Value offset
            const v_z = exec_ctx.registers[10]; // Value size

            span.debug("Host call: write storage for service {d}", .{ctx_regular.service_id});
            span.debug("Key ptr: 0x{x}, Key size: {d}, Value ptr: 0x{x}, Value size: {d}", .{
                k_o, k_z, v_o, v_z,
            });

            // Get service account - always use the current service for writing
            span.debug("Looking up service account", .{});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                // Service not found, should never happen but handle gracefully
                span.err("Could get create mutable instance of service accounts", .{});
                return .{ .terminal = .panic };
            } orelse {
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
            var key_input = std.ArrayList(u8).init(ctx_regular.allocator);
            defer key_input.deinit();

            // Add service ID as bytes (4 bytes in little-endian)
            var service_id_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &service_id_bytes, ctx_regular.service_id, .little);
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
                    ctx_regular.allocator.free(entry.value);
                    return .play;
                }
                span.debug("Key not found, returning NONE", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE);
                return .play;
            }

            // Read value from memory
            span.debug("Reading value data from memory at 0x{x} len={d}", .{ v_o, v_z });
            const value = exec_ctx.memory.readSlice(@truncate(v_o), @truncate(v_z)) catch {
                span.err("Memory access failed while reading value data", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Value data len={d} (first 32 bytes max): {s}", .{
                value.len,
                std.fmt.fmtSliceHexLower(value[0..@min(32, value.len)]),
            });

            // Write to storage
            span.debug("Writing to storage, value size: {d}", .{value.len});
            // Get current value length if key exists

            // Write and get the prior value owned
            var maybe_prior_value: ?[]const u8 = pv: {
                const value_owned = ctx_regular.allocator.dupe(u8, value) catch {
                    return .{ .terminal = .panic };
                };
                break :pv service_account.writeStorage(storage_key, value_owned) catch {
                    ctx_regular.allocator.free(value_owned);
                    span.err("Failed to write to storage, returning FULL", .{});
                    return .{ .terminal = .panic };
                };
            };
            defer if (maybe_prior_value) |pv| ctx_regular.allocator.free(pv);

            if (maybe_prior_value) |_| {
                span.debug("Prior value found, length: {d}", .{maybe_prior_value.?});
            } else {
                span.debug("No prior value found", .{});
            }

            // Check if service has enough balance to store this data
            span.debug("Checking storage footprint against balance", .{});
            const footprint = service_account.storageFootprint();
            if (footprint.a_t > service_account.balance) {
                span.debug("Insufficient balance for storage, returning FULL", .{});
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
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.FULL);
                return .play;
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
                @intFromEnum(HostCallReturnCode.NONE);

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
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_info);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: service ID and output pointer
            const service_id = exec_ctx.registers[7];
            const output_ptr = exec_ctx.registers[8];

            span.debug("Host call: info for service {d}", .{service_id});
            span.debug("Output pointer: 0x{x}", .{output_ptr});

            // Get service account based on special cases as per graypaper
            const service_account = if (service_id == 0xFFFFFFFFFFFFFFFF) blk: {
                span.debug("Using current service ID: {d}", .{ctx_regular.service_id});
                break :blk ctx_regular.context.service_accounts.getReadOnly(ctx_regular.service_id);
            } else blk: {
                span.debug("Looking up service ID: {d}", .{service_id});
                break :blk ctx_regular.context.service_accounts.getReadOnly(@intCast(service_id));
            };

            if (service_account == null) {
                span.debug("Service not found, returning NONE", .{});
                // Service not found, return error status
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.NONE);
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
                .total_storage_size = fprint.a_l,
                .total_items = fprint.a_i,
            };

            var service_info_buffer: [@sizeOf(ServiceInfo)]u8 = undefined;
            var fb = std.io.fixedBufferStream(&service_info_buffer);

            // // FIXME: this is to conform to JamDuna format
            // // remove once fixed
            // fb.writer().writeByte(0x07) catch {};

            // Serialize
            @import("../../codec.zig").serialize(
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
            span.trace("Encoded Info: {}", .{std.fmt.fmtSliceHexLower(encoded)});
            exec_ctx.memory.writeSlice(@truncate(output_ptr), encoded) catch {
                span.err("Memory access failed while writing info data", .{});
                return .{ .terminal = .panic };
            };

            // Return success
            span.debug("Info request successful", .{});
            exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.OK);
            return .play;
        }

        /// Host call implementation for transfer (Ω_T)
        pub fn transfer(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_transfer);
            defer span.deinit();

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: [d, a, l, o]
            const destination_id = exec_ctx.registers[7]; // Destination service ID
            const amount = exec_ctx.registers[8]; // Amount to transfer
            const gas_limit = exec_ctx.registers[9]; // Gas limit for on_transfer
            const memo_ptr = exec_ctx.registers[10]; // Pointer to memo data

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10 + @as(i64, @intCast(gas_limit));

            span.debug("Host call: transfer from service {d} to {d}", .{
                ctx_regular.service_id, destination_id,
            });
            span.debug("Amount: {d}, Gas limit: {d}, Memo ptr: 0x{x}", .{
                amount, gas_limit, memo_ptr,
            });

            // Get source service account
            span.debug("Looking up source service account", .{});
            const source_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Source service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Check if destination service exists
            span.debug("Looking up destination service account", .{});
            const destination_service = ctx_regular.context.service_accounts.getReadOnly(@intCast(destination_id)) orelse {
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
                .sender = ctx_regular.service_id,
                .destination = @intCast(destination_id),
                .amount = @intCast(amount),
                .memo = memo,
                .gas_limit = @intCast(gas_limit),
            };

            // Add the transfer to the list of deferred transfers
            span.debug("Adding transfer to deferred transfers list", .{});
            ctx_regular.deferred_transfers.append(deferred_transfer) catch {
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
        pub fn newService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_new_service);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const code_hash_ptr = exec_ctx.registers[7];
            const code_len: u32 = @truncate(exec_ctx.registers[8]);
            const min_gas_limit = exec_ctx.registers[9];
            const min_memo_gas = exec_ctx.registers[10];

            span.debug("Host call: new service from service {d}", .{ctx_regular.service_id});
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
            const calling_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance", .{});
                return .{ .terminal = .panic };
            } orelse {
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
            span.debug("Creating new service account with ID: {d}", .{ctx_regular.new_service_id});
            var new_account = ctx_regular.context.service_accounts.createService(ctx_regular.new_service_id) catch {
                span.err("Failed to create new service account", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Setting new account properties", .{});
            new_account.code_hash = code_hash;
            new_account.min_gas_accumulate = min_gas_limit;
            new_account.min_gas_on_transfer = min_memo_gas;
            new_account.balance = initial_balance;

            span.debug("Integrating preimage lookup", .{});
            new_account.solicitPreimage(code_hash, code_len, ctx_regular.context.time.current_slot) catch {
                span.err("Failed to integrate preimage lookup, out of memory", .{});
                return .{ .terminal = .panic };
            };

            // Deduct the initial balance from the calling service
            span.debug("Deducting {d} from calling service balance", .{initial_balance});
            calling_service.balance -= initial_balance;

            // Success result
            span.debug("Service created successfully, returning service ID: {d}", .{
                ctx_regular.new_service_id,
            });
            exec_ctx.registers[7] = ctx_regular.new_service_id; // Return the new service ID on success
            ctx_regular.new_service_id = service_util.check(&ctx_regular.context.service_accounts, ctx_regular.new_service_id); // Return the new service ID on success
            return .play;
        }

        /// Host call implementation for solicit preimage (Ω_S)
        pub fn solicitPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_solicit);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;
            const current_timeslot = ctx_regular.context.time.current_slot;

            // Get registers per graypaper B.7: [o, z]
            const hash_ptr = exec_ctx.registers[7]; // Hash pointer
            const preimage_size = exec_ctx.registers[8]; // Preimage size

            span.debug("Host call: solicit preimage for service {d}", .{ctx_regular.service_id});
            span.debug("Hash ptr: 0x{x}, Preimage size: {d}", .{ hash_ptr, preimage_size });

            // Read hash from memory
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash_slice = exec_ctx.memory.readSlice(@truncate(hash_ptr), 32) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            const hash: [32]u8 = hash_slice[0..32].*;
            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Get mutable service account
            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.HUH);
                return .play;
            };

            // Calculate storage footprint for the preimage
            const additional_storage_size: u64 = 81 + preimage_size; // 81 bytes overhead + preimage size

            // Check if service has enough balance to store this data
            span.debug("Checking if service has enough balance to store preimage", .{});
            const footprint = service_account.storageFootprint();
            const additional_balance_needed = params.min_balance_per_item +
                params.min_balance_per_octet * additional_storage_size;

            if (footprint.a_t + additional_balance_needed > service_account.balance) {
                span.debug("Insufficient balance for soliciting preimage, returning FULL", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.FULL);
                return .play;
            }

            // Try to solicit the preimage
            span.debug("Attempting to solicit preimage", .{});
            if (service_account.solicitPreimage(hash, @intCast(preimage_size), current_timeslot)) |_| {
                // Success, preimage solicited
                span.debug("Preimage solicited successfully", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.OK);
            } else |err| {
                // Error occurred while soliciting preimage
                span.err("Error while soliciting preimage: {}", .{err});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.HUH);
            }

            return .play;
        }

        /// Host call implementation for forget preimage (Ω_F)
        pub fn forgetPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_forget);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            var ctx_regular = &host_ctx.regular;
            const current_timeslot = ctx_regular.context.time.current_slot;

            // Get registers: [o, z] - hash pointer and size
            const hash_ptr = exec_ctx.registers[7];
            const preimage_size = exec_ctx.registers[8];

            span.debug("Host call: forget preimage", .{});
            span.debug("Hash ptr: 0x{x}, Hash size: {d}", .{ hash_ptr, preimage_size });

            // Read hash from memory
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash_slice = exec_ctx.memory.readSlice(@truncate(hash_ptr), 32) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            const hash: [32]u8 = hash_slice[0..32].*;
            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Get mutable service account
            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.HUH);
                return .play;
            };

            // Try to forget the preimage, this either succeeds and mutates the service, or fails and it did not mutate
            span.debug("Attempting to forget preimage", .{});
            // span.trace("Service Account: {}", .{types.fmt.format(service_account)});
            service_account.forgetPreimage(hash, @intCast(preimage_size), current_timeslot, params.preimage_expungement_period) catch {
                span.err("Error while forgetting preimage", .{});
                exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.HUH);
                return .play;
            };

            // Success result
            span.debug("Preimage forgotten successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.OK);
            return .play;
        }

        /// Host call implementation for yield (Ω_P)
        pub fn yieldAccumulationResult(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) PVM.HostCallResult {
            const span = trace.span(.host_call_yield);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers: hash pointer to read from
            const hash_ptr = exec_ctx.registers[7];

            span.debug("Host call: yield accumulation result", .{});
            span.debug("Hash pointer: 0x{x}", .{hash_ptr});

            // Read hash from memory
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash_slice = exec_ctx.memory.readSlice(@truncate(hash_ptr), 32) catch {
                // Error: memory access failed
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Accumulation output hash: {s}", .{std.fmt.fmtSliceHexLower(hash_slice)});

            // Set the accumulation output
            ctx_regular.accumulation_output = hash_slice[0..32].*;

            // Return success
            span.debug("Yield successful", .{});
            exec_ctx.registers[7] = @intFromEnum(HostCallReturnCode.OK);
            return .play;
        }
    };
}
