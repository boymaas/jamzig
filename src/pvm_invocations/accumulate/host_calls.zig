const std = @import("std");
const types = @import("../../types.zig");
const state = @import("../../state.zig");
const state_keys = @import("../../state_keys.zig");

const general = @import("../host_calls_general.zig");
const host_calls = @import("../host_calls.zig");

const service_util = @import("service_util.zig");
const DeferredTransfer = @import("types.zig").DeferredTransfer;
const AccumulationContext = @import("context.zig").AccumulationContext;
const Params = @import("../../jam_params.zig").Params;

const ReturnCode = host_calls.ReturnCode;
const HostCallError = host_calls.HostCallError;

const PVM = @import("../../pvm.zig").PVM;

// Add tracing import
const trace = @import("../../tracing.zig").scoped(.host_calls);

// Import shared encoding utilities
const encoding_utils = @import("../encoding_utils.zig");

pub fn HostCalls(comptime params: Params) type {
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

        /// Key for tracking provided preimages
        pub const ProvidedKey = struct {
            service_id: types.ServiceId,
            hash: types.Hash,
            size: u32, // Need size for lookup key
        };

        /// Context maintained during host call execution
        pub const Dimension = struct {
            allocator: std.mem.Allocator,
            context: AccumulationContext(params),
            service_id: types.ServiceId,
            new_service_id: types.ServiceId,
            deferred_transfers: std.ArrayList(DeferredTransfer),
            accumulation_output: ?types.AccumulateRoot,
            operands: []const @import("../accumulate.zig").AccumulationOperand,
            // Track provided preimages (x_p set) for post-accumulation integration
            provided_preimages: std.AutoHashMap(ProvidedKey, []const u8),

            pub fn commit(self: *@This()) !void {
                try self.context.commit();
            }

            pub fn deepClone(self: *const @This()) !@This() {
                // Create a new context with the same allocator
                var cloned_preimages = std.AutoHashMap(ProvidedKey, []const u8).init(self.allocator);
                errdefer cloned_preimages.deinit();

                // Clone all provided preimages
                var iter = self.provided_preimages.iterator();
                while (iter.next()) |entry| {
                    const data_copy = try self.allocator.dupe(u8, entry.value_ptr.*);
                    try cloned_preimages.put(entry.key_ptr.*, data_copy);
                }

                const new_context = @This(){
                    .allocator = self.allocator,
                    .context = try self.context.deepClone(),
                    .service_id = self.service_id,
                    .new_service_id = self.new_service_id,
                    .deferred_transfers = try self.deferred_transfers.clone(),
                    .accumulation_output = self.accumulation_output,
                    .operands = self.operands,
                    .provided_preimages = cloned_preimages,
                };

                return new_context;
            }

            pub fn toGeneralContext(self: *@This()) general.GeneralHostCalls(params).Context {
                return general.GeneralHostCalls(params).Context.init(
                    self.service_id,
                    &self.context.service_accounts,
                    self.allocator,
                );
            }

            pub fn deinit(self: *@This()) void {
                // Free all provided preimage data
                var iter = self.provided_preimages.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.value_ptr.*);
                }
                self.provided_preimages.deinit();

                self.deferred_transfers.deinit();
                self.context.deinit();
                self.* = undefined;
            }
        };

        /// Host call implementation for gas remaining (Ω_G)
        pub fn gasRemaining(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            return general.GeneralHostCalls(params).gasRemaining(exec_ctx);
        }

        /// Host call implementation for lookup preimage (Ω_L)
        pub fn lookupPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            var ctx_regular = &host_ctx.regular;

            return general.GeneralHostCalls(params).lookupPreimage(
                exec_ctx,
                ctx_regular.toGeneralContext(),
            );
        }

        /// Host call implementation for read storage (Ω_R)
        pub fn readStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            var ctx_regular = &host_ctx.regular;

            return general.GeneralHostCalls(params).readStorage(
                exec_ctx,
                ctx_regular.toGeneralContext(),
            );
        }

        /// Host call implementation for write storage (Ω_W)
        pub fn writeStorage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            var ctx_regular = &host_ctx.regular;

            return general.GeneralHostCalls(params).writeStorage(
                exec_ctx,
                ctx_regular.toGeneralContext(),
            );
        }

        /// Host call implementation for info service (Ω_I)
        pub fn infoService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            var ctx_regular = &host_ctx.regular;

            return general.GeneralHostCalls(params).infoService(
                exec_ctx,
                ctx_regular.toGeneralContext(),
            );
        }

        /// Host call implementation for bless service (Ω_B)
        pub fn blessService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_bless);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: [m, a, v, o, n] = registers[7..+5]
            const manager_service_id: u32 = @truncate(exec_ctx.registers[7]); // m: Manager service ID
            const assign_ptr: u32 = @truncate(exec_ctx.registers[8]); // a: Pointer to assign service IDs array
            const validator_service_id: u32 = @truncate(exec_ctx.registers[9]); // v: Validator service ID
            const always_accumulate_ptr: u32 = @truncate(exec_ctx.registers[10]); // o: Pointer to always-accumulate services array
            const always_accumulate_count: u32 = @truncate(exec_ctx.registers[11]); // n: Number of entries in always-accumulate array

            span.debug("Host call: bless - m={d}, v={d}, always_accumulate_count={d}", .{
                manager_service_id, validator_service_id, always_accumulate_count,
            });

            // Get current privileges
            const current_privileges: *state.Chi = ctx_regular.context.privileges.getMutable() catch {
                span.err("Could not get mutable privileges", .{});
                return HostCallError.FULL;
            };

            // Only the current manager service can call bless
            // Graypaper: returns HUH when x_s ≠ (x_u)_m
            if (ctx_regular.service_id != current_privileges.manager) {
                span.debug("Unauthorized bless call from service {d}, current manager is {d}", .{
                    ctx_regular.service_id, current_privileges.manager,
                });
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.HUH);
                return .play;
            }

            // Check manager and validator service IDs are valid
            if ((!ctx_regular.context.service_accounts.contains(manager_service_id)) or
                (!ctx_regular.context.service_accounts.contains(validator_service_id)))
            {
                span.debug("Manager or validator service ID doesn't exist", .{});
                return HostCallError.WHO;
            }

            // Read assign service IDs from memory
            // Graypaper: 𝐚 = decode_4(memory[a..a+4C]) where C = core_count
            const assign_memory_size = params.core_count * 4; // Each service ID is 4 bytes
            span.debug("Reading assign service IDs from memory at 0x{x}, size={d} bytes ({d} cores)", .{ assign_ptr, assign_memory_size, params.core_count });

            // Read memory for assign service IDs (exactly C service IDs)
            var assign_data = exec_ctx.memory.readSlice(@truncate(assign_ptr), assign_memory_size) catch {
                span.err("Memory access failed while reading assign service IDs", .{});
                return .{ .terminal = .panic };
            };
            defer assign_data.deinit();

            // Create a list of assign service IDs
            var assign_services = std.ArrayList(types.ServiceId).init(ctx_regular.allocator);
            defer assign_services.deinit();

            // Parse exactly C service IDs from memory
            var i: usize = 0;
            while (i < params.core_count) : (i += 1) {
                const offset = i * 4;
                const service_id = std.mem.readInt(u32, assign_data.buffer[offset..][0..4], .little);

                span.debug("Assign service {d}: ID={d}", .{ i, service_id });

                // Verify this service exists
                if (!ctx_regular.context.service_accounts.contains(service_id)) {
                    span.warn("Assign service ID {d} doesn't exist", .{service_id});
                    // FIXME: QUESTION not specified in the graypaper but makes sense
                    // return HostCallError.WHO;
                }

                // Add to the list
                assign_services.append(service_id) catch {
                    span.err("Failed to add service to assign list", .{});
                    return .{ .terminal = .panic };
                };
            }

            // Read always-accumulate service definitions from memory
            span.debug("Reading always-accumulate services from memory at 0x{x}", .{always_accumulate_ptr});

            // Calculate required memory size: each entry is 12 bytes (4 bytes service ID + 8 bytes gas)
            const required_memory_size = always_accumulate_count * 12;

            // Read memory for always-accumulate services
            var always_accumulate_data: PVM.Memory.MemorySlice = if (always_accumulate_count > 0)
                exec_ctx.memory.readSlice(@truncate(always_accumulate_ptr), required_memory_size) catch {
                    span.err("Memory access failed while reading always-accumulate services", .{});
                    return .{ .terminal = .panic };
                }
            else
                .{ .buffer = &[_]u8{} };
            defer always_accumulate_data.deinit();

            // Create a new always-accumulate services map
            var always_accumulate_services = std.AutoHashMap(types.ServiceId, types.Gas).init(ctx_regular.allocator);
            defer always_accumulate_services.deinit();

            // Parse the always-accumulate services from the memory
            var k: usize = 0;
            while (k < always_accumulate_count) : (k += 1) {
                const offset = k * 12;

                // Read service ID (4 bytes) and gas limit (8 bytes)
                const service_id = std.mem.readInt(u32, always_accumulate_data.buffer[offset..][0..4], .little);
                const gas_limit = std.mem.readInt(u64, always_accumulate_data.buffer[offset + 4 ..][0..8], .little);

                span.debug("Always-accumulate service {d}: ID={d}, gas={d}", .{ k, service_id, gas_limit });

                // Verify this service exists
                // TODO: GP This seems not to be explicitly defined in the graypaper
                if (!ctx_regular.context.service_accounts.contains(service_id)) {
                    span.warn("Always-accumulate service ID {d} doesn't exist", .{service_id});
                    // FIXME: QUESTION not specified in the graypaper but makes sense
                    // return HostCallError.WHO;
                }

                // Add to the map
                always_accumulate_services.put(service_id, gas_limit) catch {
                    span.err("Failed to add service to always-accumulate map", .{});
                    return .{ .terminal = .panic };
                };
            }

            // Update privileges
            span.debug("Updating privileges", .{});

            // Update the manager and validator service IDs
            current_privileges.manager = manager_service_id;
            current_privileges.designate = validator_service_id;

            // Update the assign service IDs list
            current_privileges.assign.clearRetainingCapacity();
            for (assign_services.items) |service_id| {
                current_privileges.assign.append(ctx_regular.allocator, service_id) catch {
                    span.err("Failed to update assign services", .{});
                    return .{ .terminal = .panic };
                };
            }

            // Update the always-accumulate services
            current_privileges.always_accumulate.clearRetainingCapacity();
            var it = always_accumulate_services.iterator();
            while (it.next()) |entry| {
                current_privileges.always_accumulate.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    span.err("Failed to update always-accumulate services", .{});
                    return .{ .terminal = .panic };
                };
            }

            // Return success
            span.debug("Services blessed successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for upgrade service (Ω_U)
        pub fn upgradeService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_upgrade);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: [o, g, m]
            const code_hash_ptr = exec_ctx.registers[7]; // Pointer to new code hash (o)
            const min_gas_limit = exec_ctx.registers[8]; // New gas limit for accumulate (g)
            const min_memo_gas = exec_ctx.registers[9]; // New gas limit for on_transfer (m)

            span.debug("Host call: upgrade service {d}", .{ctx_regular.service_id});
            span.debug("Code hash ptr: 0x{x}, Min gas: {d}, Min memo gas: {d}", .{
                code_hash_ptr, min_gas_limit, min_memo_gas,
            });

            // Read code hash from memory
            span.debug("Reading code hash from memory at 0x{x}", .{code_hash_ptr});
            var code_hash = exec_ctx.memory.readHash(@truncate(code_hash_ptr)) catch {
                span.err("Memory access failed while reading code hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Code hash: {s}", .{std.fmt.fmtSliceHexLower(&code_hash)});

            // Get mutable service account - this is always the current service
            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Update the service account code hash and gas limits
            span.debug("Updating service account properties", .{});
            service_account.code_hash = code_hash;
            service_account.min_gas_accumulate = min_gas_limit;
            service_account.min_gas_on_transfer = min_memo_gas;

            // Success result
            span.debug("Service upgraded successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for transfer (Ω_T)
        pub fn transfer(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
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
                return HostCallError.WHO;
            };

            // Check if gas limit is high enough for destination service's on_transfer
            span.debug("Checking gas limit against destination service's min_gas_on_transfer: {d}", .{
                destination_service.min_gas_on_transfer,
            });
            if (gas_limit < destination_service.min_gas_on_transfer) {
                span.debug("Gas limit too low, returning LOW error", .{});
                return HostCallError.LOW;
            }

            // Check if source has enough balance
            span.debug("Checking source balance: {d} against transfer amount: {d}", .{
                source_service.balance, amount,
            });
            if (source_service.balance < amount) {
                span.debug("Insufficient balance, returning CASH error", .{});
                return HostCallError.CASH;
            }

            // Read memo data from memory
            span.debug("Reading memo data from memory at 0x{x}", .{memo_ptr});
            var memo_slice = exec_ctx.memory.readSlice(@truncate(memo_ptr), params.transfer_memo_size) catch {
                span.err("Memory access failed while reading memo data", .{});
                return .{ .terminal = .panic };
            };
            defer memo_slice.deinit();

            span.trace("Memo data (first 32 bytes max): {s}", .{
                std.fmt.fmtSliceHexLower(memo_slice.buffer[0..@min(32, memo_slice.buffer.len)]),
            });

            // Create a memo buffer and copy data from memory
            var memo: [128]u8 = [_]u8{0} ** 128;
            @memcpy(memo[0..@min(memo_slice.buffer.len, 128)], memo_slice.buffer[0..@min(memo_slice.buffer.len, 128)]);

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
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for assign core (Ω_A)
        pub fn assignCore(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_assign);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: [c, o, a] = ω[7..+3]
            const core_index = exec_ctx.registers[7]; // c: Core index to assign
            const output_ptr = exec_ctx.registers[8]; // o: Pointer to authorizer queue data
            const new_assign_service = exec_ctx.registers[9]; // a: New assign service ID

            // Check if core index is valid: c < C
            if (core_index >= params.core_count) {
                span.debug("Invalid core index {d}, returning CORE error", .{core_index});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.CORE);
                return .play;
            }

            // Get mutable access to privileges (Chi) to check authorization and update
            const privileges: *state.Chi = ctx_regular.context.privileges.getMutable() catch {
                span.err("Problem getting mutable privileges", .{});
                return .{ .terminal = .panic };
            };

            // Authorization check: x_s must equal (x_u)_a[c]
            // Only the current assign service for this core can update it
            if (ctx_regular.service_id != privileges.assign.items[core_index]) {
                span.debug("Service {d} is not the assign service for core {d} (current assign: {d}), returning HUH", .{ ctx_regular.service_id, core_index, privileges.assign.items[core_index] });
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.HUH);
                return .play;
            }

            // Read authorizer hashes from memory - each hash is 32 bytes, and we need to read params.max_authorizations_queue_items of them
            span.debug("Reading authorizer hashes from memory at 0x{x}", .{output_ptr});

            // Calculate the total size of all authorizer hashes
            const total_size: u32 = 32 * @as(u32, params.max_authorizations_queue_items);

            // Read all hashes at once
            var hashes_data = exec_ctx.memory.readSlice(@truncate(output_ptr), total_size) catch {
                span.err("Memory access failed while reading authorizer hashes", .{});
                return .{ .terminal = .panic };
            };
            defer hashes_data.deinit();

            // Create a sequence of authorizer hashes
            const authorizer_hashes = std.mem.bytesAsSlice(types.AuthorizerHash, hashes_data.buffer);

            for (authorizer_hashes, 0..) |hash, i| {
                span.trace("Authorizer hash {d}: {s}", .{ i, std.fmt.fmtSliceHexLower(&hash) });
            }

            // Get mutable access to the authorizer queue
            span.debug("Updating authorizer queue for core {d}", .{core_index});
            const auth_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items) = ctx_regular.context.authorizer_queue.getMutable() catch {
                span.err("Problem getting mutable authorizer queue", .{});
                return .{ .terminal = .panic };
            };

            // Update BOTH components as per graypaper:
            // 1. (x'_u)_q[c] = q (new authorizer queue)
            for (0..params.max_authorizations_queue_items) |i| {
                auth_queue.setAuthorization(core_index, i, authorizer_hashes[i]) catch {
                    span.err("Failed to set authorization at index {d} for core {d}", .{ i, core_index });
                    return .{ .terminal = .panic };
                };
            }

            // 2. (x'_u)_a[c] = a (new assign service)
            privileges.assign.items[core_index] = @intCast(new_assign_service);
            span.debug("Updated assign service for core {d} to service {d}", .{ core_index, new_assign_service });

            // Return success
            span.debug("Core assigned successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for checkpoint (Ω_C)
        pub fn checkpoint(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_checkpoint);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            // According to graypaper B.7, the checkpoint operation:
            // 1. Sets the exceptional dimension to the value of the regular dimension
            // 2. Returns the remaining gas in register 7

            span.debug("Host call: checkpoint - cloning regular context to exceptional", .{});

            // Clone the regular context to the exceptional context
            // This involves a deep copy of all state to ensure complete isolation
            host_ctx.exceptional.deinit();
            host_ctx.exceptional = host_ctx.regular.deepClone() catch {
                return .{ .terminal = .panic };
            };

            // Return the remaining gas as per the specification
            exec_ctx.registers[7] = @intCast(exec_ctx.gas);

            span.debug("Checkpoint created successfully, remaining gas: {d}", .{exec_ctx.gas});
            return .play;
        }

        /// Host call implementation for new service (Ω_N)
        pub fn newService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
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
            const free_storage_offset = exec_ctx.registers[11];

            span.debug("Host call: new service from service {d}", .{ctx_regular.service_id});
            span.debug("Code hash ptr: 0x{x}, Code len: {d}", .{ code_hash_ptr, code_len });
            span.debug("Min gas limit: {d}, Min memo gas: {d}, Free storage: {d}", .{ min_gas_limit, min_memo_gas, free_storage_offset });

            // Read code hash from memory
            span.debug("Reading code hash from memory at 0x{x}", .{code_hash_ptr});
            var code_hash = exec_ctx.memory.readHash(@truncate(code_hash_ptr)) catch {
                span.err("Memory access failed while reading code hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Code hash: {s}", .{std.fmt.fmtSliceHexLower(&code_hash)});

            // Check free storage grant permission: only manager can grant free storage
            if (free_storage_offset != 0) {
                const privileges = ctx_regular.context.privileges.getReadOnly();
                if (ctx_regular.service_id != privileges.manager) {
                    span.debug("Non-manager (service {d}) trying to grant free storage, manager is {d}", .{
                        ctx_regular.service_id, privileges.manager,
                    });
                    return HostCallError.HUH;
                }
                span.debug("Manager granting {d} bytes of free storage", .{free_storage_offset});
            }

            // Get the calling service account
            span.debug("Looking up calling service account", .{});
            const calling_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Calling service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            // Create the new service account first
            span.debug("Creating new service account with ID: {d}", .{ctx_regular.new_service_id});
            var new_account = ctx_regular.context.service_accounts.createService(ctx_regular.new_service_id) catch {
                span.err("Failed to create new service account", .{});
                return .{ .terminal = .panic };
            };

            // Set all properties except balance
            span.debug("Setting new account properties", .{});
            new_account.code_hash = code_hash;
            new_account.min_gas_accumulate = min_gas_limit;
            new_account.min_gas_on_transfer = min_memo_gas;
            new_account.storage_offset = free_storage_offset;
            new_account.parent_service = ctx_regular.service_id;
            new_account.creation_slot = ctx_regular.context.time.current_slot;
            new_account.last_accumulation_slot = 0;
            new_account.balance = 0; // Temporary, will be set after footprint calculation

            // Solicit preimage - this updates the footprint tracking
            span.debug("Integrating preimage lookup", .{});
            new_account.solicitPreimage(ctx_regular.new_service_id, code_hash, code_len, ctx_regular.context.time.current_slot) catch {
                span.err("Failed to integrate preimage lookup, out of memory", .{});
                // FIXME: Should rollback service creation here
                return .{ .terminal = .panic };
            };

            // Now calculate the actual threshold balance using storageFootprint
            const footprint = new_account.storageFootprint();
            const initial_balance = footprint.a_t;

            span.debug("Footprint: items={d}, bytes={d}, threshold={d}", .{
                footprint.a_i, footprint.a_o, footprint.a_t,
            });
            span.debug("Initial balance required: {d}, caller balance: {d}", .{
                initial_balance, calling_service.balance,
            });

            // Check if caller has enough balance
            if (calling_service.balance < initial_balance) {
                span.debug("Insufficient balance to create new service, returning CASH error", .{});
                // TODO: Should rollback service creation here
                return HostCallError.CASH;
            }

            // Set the balance and deduct from caller
            new_account.balance = initial_balance;
            calling_service.balance -= initial_balance;
            span.debug("Set new service balance to {d}, deducted from calling service", .{initial_balance});

            // Success result
            span.debug("Service created successfully, returning service ID: {d}", .{
                ctx_regular.new_service_id,
            });
            exec_ctx.registers[7] = ctx_regular.new_service_id; // Return the new service ID on success
            ctx_regular.new_service_id = service_util.check(&ctx_regular.context.service_accounts, ctx_regular.new_service_id); // Return the new service ID on success
            return .play;
        }

        /// Host call implementation for eject service (Ω_J)
        pub fn ejectService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_eject);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: [d, o]
            const target_service_id = exec_ctx.registers[7]; // Service ID to eject (d)
            const hash_ptr = exec_ctx.registers[8]; // Hash pointer (o)

            span.debug("Host call: eject service {d}", .{target_service_id});
            span.debug("Hash pointer: 0x{x}", .{hash_ptr});

            // Check if target service is current service (can't eject self)
            if (target_service_id == ctx_regular.service_id) {
                span.debug("Cannot eject current service, returning WHO error", .{});
                return HostCallError.WHO;
            }

            // Get target service account (must exist)
            const target_service = ctx_regular.context.service_accounts.getReadOnly(@intCast(target_service_id)) orelse {
                span.debug("Target service not found, returning WHO error", .{});
                return HostCallError.WHO;
            };

            // Read hash from memory
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Get the current_service
            const current_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of current service", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Current service not found (should never happen)", .{});
                return .{ .terminal = .panic };
            };

            if (!std.mem.eql(u8, &current_service.code_hash, &target_service.code_hash)) {
                span.debug("Target service code hash doesn't match current code hah, returning WHO error", .{});
                return HostCallError.WHO;
            }

            // Per graypaper, check if the lookup status has a valid record
            // First determine the length
            const footprint = target_service.storageFootprint();
            const l = @max(81, footprint.a_o) - 81;
            const lookup_status = target_service.getPreimageLookup(@intCast(target_service_id), hash, @intCast(l)) orelse {
                span.debug("Hash lookup not found, returning HUH error", .{});
                return HostCallError.HUH;
            };

            // Seems we should only have one preimage_lookup and nothing in the storage
            // that is the only way this can a_i
            if (footprint.a_i != 2) {
                return HostCallError.HUH;
            }

            const current_timeslot = ctx_regular.context.time.current_slot;
            const status = lookup_status.asSlice();

            // Check various conditions for lookup status per graypaper B.7
            // d_i != 2: The lookup item index must be 2
            if (status.len != 2) {
                span.debug("Lookup status length is not 2, returning HUH error", .{});
                return HostCallError.HUH;
            }

            // Check if time condition is met for preimage expungement
            if (status[1].? >= current_timeslot -| params.preimage_expungement_period) {
                span.debug("Preimage not yet expired, returning HUH error", .{});
                return HostCallError.HUH;
            }

            // All checks passed, can eject the service
            span.debug("Ejecting service {d}", .{target_service_id});

            const target_balance = target_service.balance;

            // Remove the service from the state, do this first, as this could fail
            // and we do not want to have altered state
            _ = ctx_regular.context.service_accounts.removeService(@intCast(target_service_id)) catch {
                span.err("Failed to remove service", .{});
                return .{ .terminal = .panic };
            };

            // Transfer the ejected service's balance to the current service
            span.debug("Transferring balance {d} from ejected service to current service", .{target_balance});
            current_service.balance += target_balance;

            // Return success
            span.debug("Service ejected successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for query preimage (Ω_Q)
        /// Queries the availability status of a preimage and returns encoded timestamps
        pub fn queryPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_query);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper B.7: [o, z]
            const hash_ptr = exec_ctx.registers[7]; // Hash pointer (o)
            const preimage_size = exec_ctx.registers[8]; // Preimage size (z)

            span.debug("Host call: query preimage for service {d}", .{ctx_regular.service_id});
            span.debug("Hash ptr: 0x{x}, Preimage size: {d}", .{ hash_ptr, preimage_size });

            // Read hash from memory
            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Get service account
            span.debug("Getting service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getReadOnly(ctx_regular.service_id) orelse {
                span.err("Service account not found", .{});
                return .{ .terminal = .panic };
            };

            // Query preimage status
            // Note: Accessing service_account.getPreimageLookup is equivalent to graypaper's (x_s)_l notation
            // Both refer to the same preimage lookup table data structure in the service state
            span.debug("Querying preimage status", .{});
            const lookup_status = service_account.getPreimageLookup(ctx_regular.service_id, hash, @intCast(preimage_size)) orelse {
                span.debug("Preimage lookup not found, returning NONE", .{});
                exec_ctx.registers[8] = 0;  // Per graypaper: R8 = 0 when lookup doesn't exist
                return HostCallError.NONE;
            };

            // Encode result according to graypaper section B.7
            var result: u64 = 0;
            var result_high: u64 = 0;

            // Per graypaper the encoding is:
            // - 0,0 if empty entry: a = []
            // - 1 + 2^32 * x,0 if available since time x: a = [x]
            // - 2 + 2^32 * x,y if unavailable since time y, was available from x: a = [x,y]
            // - 3 + 2^32 * x,y + 2^32 * z if available since z, was available from x until y: a = [x,y,z]

            span.debug("Preimage status found", .{});

            const status = lookup_status.asSlice();

            switch (status.len) {
                0 => {
                    // Preimage is requested but not supplied
                    span.debug("Status: requested but not supplied", .{});
                    result = 0;
                    result_high = 0;
                },
                1 => {
                    // Preimage is available since time status[0]
                    span.debug("Status: available since time {d}", .{status[0].?});
                    result = 1 + ((@as(u64, status[0].?) << 32));
                    result_high = 0;
                },
                2 => {
                    // Preimage was available from time status[0] until status[1]
                    span.debug("Status: unavailable, was available from {d} until {d}", .{ status[0].?, status[1].? });
                    result = 2 + ((@as(u64, status[0].?) << 32));
                    result_high = status[1].?;
                },
                3 => {
                    // Preimage is available since time status[2], was available from status[0] until status[1]
                    span.debug("Status: available since {d}, previously from {d} until {d}", .{ status[2].?, status[0].?, status[1].? });
                    result = 3 + ((@as(u64, status[0].?) << 32));
                    result_high = status[1].? + ((@as(u64, status[2].?) << 32));
                },
                else => {
                    // Invalid status length, should never happen
                    span.err("Invalid preimage status length: {d}", .{status.len});
                    return .{ .terminal = .panic };
                },
            }

            // Set result registers
            exec_ctx.registers[7] = result;
            exec_ctx.registers[8] = result_high;

            span.debug("Query completed. Result: 0x{x}, High: 0x{x}", .{ result, result_high });
            return .play;
        }

        /// Host call implementation for solicit preimage (Ω_S)
        pub fn solicitPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
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
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Get mutable service account
            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found", .{});
                return HostCallError.HUH;
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
                return HostCallError.FULL;
            }

            // Try to solicit the preimage
            span.debug("Attempting to solicit preimage", .{});

            if (service_account.solicitPreimage(ctx_regular.service_id, hash, @intCast(preimage_size), current_timeslot)) |_| {
                // Success, preimage solicited
                span.debug("Preimage solicited successfully: {any}", .{service_account.getPreimageLookup(ctx_regular.service_id, hash, @intCast(preimage_size))});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            } else |err| {
                // Handle errors per graypaper: OutOfMemory → PANIC, others → HUH
                switch (err) {
                    error.OutOfMemory => {
                        span.err("Out of memory while soliciting preimage", .{});
                        return .{ .terminal = .panic };
                    },
                    error.AlreadySolicited, error.AlreadyAvailable, error.AlreadyReSolicited, error.InvalidState => {
                        span.err("Invalid solicitation attempt: {}", .{err});
                        return HostCallError.HUH;
                    },
                    else => {
                        span.err("Unexpected error while soliciting preimage: {}", .{err});
                        return HostCallError.HUH;
                    },
                }
            }

            return .play;
        }

        /// Host call implementation for forget preimage (Ω_F)
        pub fn forgetPreimage(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
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
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Get mutable service account
            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found", .{});
                return HostCallError.HUH;
            };

            // Try to forget the preimage, this either succeeds and mutates the service, or fails and it did not mutate
            span.debug("Attempting to forget preimage", .{});
            // span.trace("Service Account: {}", .{types.fmt.format(service_account.preimage_lookup)});
            service_account.forgetPreimage(ctx_regular.service_id, hash, @intCast(preimage_size), current_timeslot, params.preimage_expungement_period) catch |err| {
                span.err("Error while forgetting preimage: {}", .{err});
                return HostCallError.HUH;
            };

            // Success result
            span.debug("Preimage forgotten successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for yield (Ω_P)
        pub fn yieldAccumulationResult(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
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
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                // Error: memory access failed
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Accumulation output hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            // Set the accumulation output
            ctx_regular.accumulation_output = hash;

            // Return success
            span.debug("Yield successful", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for designate validators (Ω_D)
        pub fn designateValidators(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_designate);
            defer span.deinit();

            // Graypaper specifies exactly 336 bytes per validator
            const VALIDATOR_DATA_SIZE = 336;
            comptime {
                std.debug.assert(@sizeOf(types.ValidatorData) == VALIDATOR_DATA_SIZE);
            }

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get register per graypaper: [o] - offset to validator keys
            const offset_ptr = exec_ctx.registers[7]; // Offset to validator keys array

            span.debug("Host call: designate validators", .{});
            span.debug("Offset pointer: 0x{x}", .{offset_ptr});

            // Check if current service has the validator privilege (x_s = (x_u)_v)
            const privileges: *const state.Chi = ctx_regular.context.privileges.getReadOnly();
            // Note: Chi incorrectly names this field 'designate' but it represents the validator service
            if (privileges.designate != ctx_regular.service_id) {
                span.debug("Service {d} does not have validator privilege, current validator service is {?d}", .{
                    ctx_regular.service_id, privileges.designate,
                });
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.HUH);
                return .play;
            }

            // Calculate total size needed: VALIDATOR_DATA_SIZE bytes per validator * V validators
            const validator_count: u32 = params.validators_count;
            const total_size: u32 = VALIDATOR_DATA_SIZE * validator_count;

            span.debug("Reading {d} validators, total size: {d} bytes", .{ validator_count, total_size });

            // Read validator keys from memory
            var validator_data = exec_ctx.memory.readSlice(@truncate(offset_ptr), total_size) catch {
                span.err("Memory access failed while reading validator keys", .{});
                return .{ .terminal = .panic };
            };
            defer validator_data.deinit();

            // Parse the validator keys directly from memory using bytesAsSlice
            // Each validator is exactly VALIDATOR_DATA_SIZE bytes:
            // - 32 bytes: Bandersnatch public key
            // - 32 bytes: Ed25519 public key
            // - 144 bytes: BLS public key
            // - 128 bytes: Metadata

            // Verify the buffer size is correct
            if (validator_data.buffer.len != validator_count * VALIDATOR_DATA_SIZE) {
                span.err("Invalid validator data size: expected {d}, got {d}", .{ validator_count * VALIDATOR_DATA_SIZE, validator_data.buffer.len });
                return .{ .terminal = .panic };
            }

            // Cast the byte buffer directly to ValidatorData slice - no allocation needed!
            const validators = std.mem.bytesAsSlice(types.ValidatorData, validator_data.buffer);

            // Log some validator keys for debugging
            for (validators, 0..) |validator, i| {
                if (i < 3) { // Log first 3 validators
                    span.trace("Validator {d}: bandersnatch={s}, ed25519={s}", .{
                        i,
                        std.fmt.fmtSliceHexLower(&validator.bandersnatch),
                        std.fmt.fmtSliceHexLower(&validator.ed25519),
                    });
                }
            }

            // Update the staging validator set (iota)
            const validator_keys = ctx_regular.context.validator_keys.getMutable() catch {
                span.err("Problem getting mutable validator keys", .{});
                return .{ .terminal = .panic };
            };

            // Replace the entire validator set - duplicate the data since validator_data.buffer will be freed
            ctx_regular.allocator.free(validator_keys.validators);
            validator_keys.validators = ctx_regular.allocator.dupe(types.ValidatorData, validators) catch {
                span.err("Failed to duplicate validator data", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Updated staging validator set with {d} validators", .{validator_count});

            // Return success
            span.debug("Validators designated successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for provide (Ω_Aries)
        pub fn provide(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_provide);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            // Get registers per graypaper: [service_id*, data_ptr, data_size]
            const service_id_reg = exec_ctx.registers[7]; // Service ID (s* - can be current service if 2^64-1)
            const data_ptr = exec_ctx.registers[8]; // Data pointer (o)
            const data_size = exec_ctx.registers[9]; // Data size (z)

            span.debug("Host call: provide", .{});
            span.debug("Service ID reg: {d}, data ptr: 0x{x}, data size: {d}", .{ service_id_reg, data_ptr, data_size });

            // Determine the actual service ID using graypaper convention
            const service_id: types.ServiceId = host_calls.resolveTargetService(ctx_regular, service_id_reg);

            span.debug("Providing data for service: {d}", .{service_id});

            // Check if the service exists
            const service_account = ctx_regular.context.service_accounts.getReadOnly(service_id) orelse {
                span.debug("Service {d} not found, returning WHO error", .{service_id});
                return HostCallError.WHO;
            };

            // Read data from memory
            span.debug("Reading {d} bytes from memory at 0x{x}", .{ data_size, data_ptr });
            var data_slice = exec_ctx.memory.readSlice(@truncate(data_ptr), @truncate(data_size)) catch {
                span.err("Memory access failed while reading provide data", .{});
                return .{ .terminal = .panic };
            };
            defer data_slice.deinit();

            // Hash the data
            var data_hash: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(data_slice.buffer, &data_hash, .{});

            span.trace("Data hash: {s}", .{std.fmt.fmtSliceHexLower(&data_hash)});

            // Check if preimage was solicited (must have status [])
            const lookup = service_account.getPreimageLookup(service_id, data_hash, @intCast(data_size));
            if (lookup == null) {
                // Not solicited - no lookup exists
                span.debug("Preimage not solicited (no lookup exists), returning HUH", .{});
                return HostCallError.HUH;
            }

            const status = lookup.?.asSlice();
            if (status.len != 0) {
                // Wrong status - only [] (empty) is valid for providing
                span.debug("Preimage has wrong status (len={d}), only empty status [] allowed, returning HUH", .{status.len});
                return HostCallError.HUH;
            }

            // Check for duplicate provision
            const key = ProvidedKey{
                .service_id = service_id,
                .hash = data_hash,
                .size = @intCast(data_size),
            };
            if (ctx_regular.provided_preimages.contains(key)) {
                span.debug("Preimage already provided in this accumulation, returning HUH", .{});
                return HostCallError.HUH;
            }

            // Store in context (x_p), NOT in service
            // The data will be applied to services after accumulation completes
            // Create a copy of the data for storage
            const data_owned = data_slice.takeBufferOwnership(ctx_regular.allocator) catch {
                span.err("Failed to take ownership of data buffer", .{});
                return .{ .terminal = .panic };
            };
            ctx_regular.provided_preimages.put(key, data_owned) catch |err| {
                span.err("Failed to store provided preimage: {}", .{err});
                ctx_regular.allocator.free(data_owned);
                return .{ .terminal = .panic };
            };

            span.debug("Provision stored in context for post-accumulation integration", .{});

            // Return success
            span.debug("Provision added successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for fetch (Ω_Y) - Accumulate context
        /// ΩY(ϱ, ω, µ, ∅, η'₀, ∅, ∅, ∅, x, ∅, t)
        /// Fetch for accumulate context supporting selectors:
        /// 0: System constants
        /// 1: Current random accumulator (η'₀)
        /// 14: Operand data (from context x)
        /// 15: Specific operand by index (from context x)
        /// 16: Transfer list (from t)
        /// 17: Specific transfer by index (from t)
        pub fn fetch(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(.host_call_fetch);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular = &host_ctx.regular;

            const output_ptr = exec_ctx.registers[7]; // Output pointer (o)
            const offset = exec_ctx.registers[8]; // Offset (f)
            const limit = exec_ctx.registers[9]; // Length limit (l)
            const selector = exec_ctx.registers[10]; // Data selector
            const index1 = @as(u32, @intCast(exec_ctx.registers[11])); // Index 1

            span.debug("Host call: fetch selector={d} index1={d}", .{ selector, index1 });
            span.debug("Output ptr: 0x{x}, offset: {d}, limit: {d}", .{ output_ptr, offset, limit });

            // Determine what data to fetch based on selector
            var data_to_fetch: ?[]const u8 = null;
            var needs_cleanup = false;

            switch (selector) {
                0 => {
                    // Return JAM parameters as encoded bytes per graypaper
                    span.debug("Encoding JAM chain constants", .{});
                    const encoded_constants = encoding_utils.encodeJamParams(ctx_regular.allocator, params) catch {
                        span.err("Failed to encode JAM chain constants", .{});
                        return HostCallError.NONE;
                    };
                    data_to_fetch = encoded_constants;
                    needs_cleanup = true;
                },

                1 => {
                    // Selector 1: Current random accumulator (η'₀)
                    span.debug("Random accumulator available from accumulate context", .{});
                    data_to_fetch = ctx_regular.context.entropy[0..];
                },

                14 => {
                    // Selector 14: Encoded operand tuples
                    const operand_tuples_data = encoding_utils.encodeOperandTuples(ctx_regular.allocator, ctx_regular.operands) catch {
                        span.err("Failed to encode operand tuples", .{});
                        return HostCallError.NONE;
                    };
                    span.debug("Operand tuples encoded successfully, count={d}", .{ctx_regular.operands.len});
                    data_to_fetch = operand_tuples_data;
                    needs_cleanup = true;
                },

                15 => {
                    // Selector 15: Specific operand tuple
                    if (index1 < ctx_regular.operands.len) {
                        const operand_tuple = &ctx_regular.operands[index1];
                        const operand_tuple_data = encoding_utils.encodeOperandTuple(ctx_regular.allocator, operand_tuple) catch {
                            span.err("Failed to encode operand tuple", .{});
                            return HostCallError.NONE;
                        };
                        span.debug("Operand tuple encoded successfully: index={d}", .{index1});
                        data_to_fetch = operand_tuple_data;
                        needs_cleanup = true;
                    } else {
                        span.debug("Operand tuple index out of bounds: index={d}, count={d}", .{ index1, ctx_regular.operands.len });
                        return HostCallError.NONE;
                    }
                },

                16 => {
                    // Selector 16: Encoded transfer sequence - access from deferred transfers
                    if (ctx_regular.deferred_transfers.items.len > 0) {
                        const transfers_data = encoding_utils.encodeTransfers(ctx_regular.allocator, ctx_regular.deferred_transfers.items) catch {
                            span.err("Failed to encode transfer sequence", .{});
                            return HostCallError.NONE;
                        };
                        span.debug("Transfer sequence encoded successfully, count={d}", .{ctx_regular.deferred_transfers.items.len});
                        data_to_fetch = transfers_data;
                        needs_cleanup = true;
                    } else {
                        span.debug("No deferred transfers available in accumulate context", .{});
                        return HostCallError.NONE;
                    }
                },

                17 => {
                    // Selector 17: Specific transfer by index
                    if (ctx_regular.deferred_transfers.items.len > 0) {
                        if (index1 < ctx_regular.deferred_transfers.items.len) {
                            const transfer_item = &ctx_regular.deferred_transfers.items[index1];
                            const transfer_data = encoding_utils.encodeTransfer(ctx_regular.allocator, transfer_item) catch {
                                span.err("Failed to encode transfer", .{});
                                return HostCallError.NONE;
                            };
                            span.debug("Transfer encoded successfully: index={d}", .{index1});
                            data_to_fetch = transfer_data;
                            needs_cleanup = true;
                        } else {
                            span.debug("Transfer index out of bounds: index={d}, count={d}", .{ index1, ctx_regular.deferred_transfers.items.len });
                            return HostCallError.NONE;
                        }
                    } else {
                        span.debug("No deferred transfers available in accumulate context", .{});
                        return HostCallError.NONE;
                    }
                },

                2...13 => {
                    // Selectors 2-13 are for work package/refine contexts only
                    // 2-3: Header data (Refine only)
                    // 4-6: Work reports (Refine only)
                    // 7-13: Work package data (Is-Authorized/Refine only)
                    span.debug("Selector {d} not available in accumulate context (work package/refine only)", .{selector});
                    return HostCallError.NONE;
                },

                else => {
                    // Invalid selector
                    span.debug("Invalid fetch selector: {d} (valid for accumulate: 0,1,14,15,16,17)", .{selector});
                    return HostCallError.NONE;
                },
            }
            defer if (needs_cleanup and data_to_fetch != null) ctx_regular.allocator.free(data_to_fetch.?);

            if (data_to_fetch) |data| {
                // Calculate what to return based on offset and limit
                const f = @min(offset, data.len);
                const l = @min(limit, data.len - f);

                span.debug("Fetching {d} bytes from offset {d} from data_to_fetch", .{ l, f });

                // Double check if we have any data to fetch
                // TODO: double check this in other memory access patterns
                const v = data[f..][0..l];
                if (v.len == 0) {
                    span.debug("Zero len offset requested, returning size: {d}", .{data.len});
                    exec_ctx.registers[7] = data.len;
                    return .play;
                }

                // Write data to memory
                exec_ctx.memory.writeSlice(@truncate(output_ptr), data[f..][0..l]) catch {
                    span.err("Memory access failed while writing fetch data", .{});
                    return .{ .terminal = .panic };
                };

                // Return the total length of the data
                exec_ctx.registers[7] = data.len;
                span.debug("Fetch successful, total length: {d}", .{data.len});
            }

            return .play;
        }

        pub fn debugLog(
            exec_ctx: *PVM.ExecutionContext,
            _: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            return general.GeneralHostCalls(params).debugLog(
                exec_ctx,
            );
        }
    };
}
