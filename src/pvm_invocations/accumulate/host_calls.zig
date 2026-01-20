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

const trace = @import("tracing").scoped(.host_calls);

const encoding_utils = @import("../encoding_utils.zig");

const pvm_accumulate = @import("../accumulate.zig");

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
            incoming_transfers: []const pvm_accumulate.TransferOperand,
            generated_transfers: std.ArrayList(pvm_accumulate.TransferOperand),
            accumulation_output: ?types.AccumulateRoot,
            operands: []const pvm_accumulate.AccumulationOperand,
            provided_preimages: std.AutoHashMap(ProvidedKey, []const u8),

            pub fn commit(self: *@This()) !void {
                try self.context.commitForService(self.service_id);
            }

            /// Apply provided preimages after accumulation
            /// Filters still-relevant preimages and updates service accounts
            pub fn applyProvidedPreimages(self: *@This(), current_timeslot: types.TimeSlot) !void {
                const span = trace.span(@src(), .apply_provided_preimages);
                defer span.deinit();

                var iter = self.provided_preimages.iterator();
                while (iter.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const data = entry.value_ptr.*;

                    span.debug("Processing provided preimage for service {d}, hash: {s}, size: {d}", .{
                        key.service_id,
                        std.fmt.fmtSliceHexLower(&key.hash),
                        key.size,
                    });

                    const service = self.context.service_accounts.getMutable(key.service_id) catch {
                        span.debug("Failed to get mutable service account {d}, skipping", .{key.service_id});
                        continue;
                    } orelse {
                        span.debug("Service {d} not found, skipping", .{key.service_id});
                        continue;
                    };

                    const lookup = service.getPreimageLookup(key.service_id, key.hash, key.size);
                    if (lookup != null and lookup.?.asSlice().len == 0) {
                        span.debug("Preimage still needed (status []), applying to service", .{});

                        const preimage_key = state_keys.constructServicePreimageKey(key.service_id, key.hash);
                        // TODO: OPTIMIZE we can optimize here to take ownership of the data
                        try service.dupeAndAddPreimage(preimage_key, data);

                        try service.registerPreimageAvailable(
                            key.service_id,
                            key.hash,
                            key.size,
                            current_timeslot,
                        );

                        span.debug("Preimage applied: stored and status updated to [{d}]", .{current_timeslot});
                    } else {
                        span.debug("Preimage not needed or already available, skipping", .{});
                    }
                }
            }

            pub fn deepClone(self: *const @This()) !@This() {
                var cloned_preimages = std.AutoHashMap(ProvidedKey, []const u8).init(self.allocator);
                errdefer cloned_preimages.deinit();

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
                    .incoming_transfers = self.incoming_transfers,
                    .generated_transfers = try self.generated_transfers.clone(),
                    .accumulation_output = self.accumulation_output,
                    .operands = self.operands,
                    .provided_preimages = cloned_preimages,
                };

                return new_context;
            }

            pub fn deepCloneHeap(self: *const @This()) !*@This() {
                const object = try self.allocator.create(@This());
                object.* = try self.deepClone();
                return object;
            }

            pub fn toGeneralContext(self: *@This()) general.GeneralHostCalls(params).Context {
                return general.GeneralHostCalls(params).Context.init(
                    self.service_id,
                    &self.context.service_accounts,
                    self.allocator,
                );
            }

            pub fn deinit(self: *@This()) void {
                var iter = self.provided_preimages.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.value_ptr.*);
                }
                self.provided_preimages.deinit();

                self.generated_transfers.deinit();
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
            const span = trace.span(@src(), .host_call_bless);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const manager_service_id: u32 = @truncate(exec_ctx.registers[7]); // m: Manager service ID
            const assign_ptr: u32 = @truncate(exec_ctx.registers[8]); // a: Pointer to assign service IDs array
            const validator_service_id: u32 = @truncate(exec_ctx.registers[9]); // v: Validator service ID
            const registrar_service_id: u32 = @truncate(exec_ctx.registers[10]); // r: Registrar service ID
            const always_accumulate_ptr: u32 = @truncate(exec_ctx.registers[11]); // o: Pointer to always-accumulate services array
            const always_accumulate_count: u32 = @truncate(exec_ctx.registers[12]); // n: Number of entries in always-accumulate array

            span.debug("Host call: bless - m={d}, v={d}, r={d}, always_accumulate_count={d}", .{
                manager_service_id, validator_service_id, registrar_service_id, always_accumulate_count,
            });

            span.debug("Reading always-accumulate services from memory at 0x{x}", .{always_accumulate_ptr});

            const required_memory_size = always_accumulate_count *| 12;

            var always_accumulate_data: PVM.Memory.MemorySlice = if (always_accumulate_count > 0)
                exec_ctx.memory.readSlice(@truncate(always_accumulate_ptr), required_memory_size) catch {
                    span.err("Memory access failed while reading always-accumulate services", .{});
                    return .{ .terminal = .panic };
                }
            else
                .{ .buffer = &[_]u8{} };
            defer always_accumulate_data.deinit();

            var always_accumulate_services = std.AutoHashMap(types.ServiceId, types.Gas).init(ctx_regular.allocator);
            defer always_accumulate_services.deinit();

            var k: usize = 0;
            while (k < always_accumulate_count) : (k += 1) {
                const offset = k * 12;

                const service_id = std.mem.readInt(u32, always_accumulate_data.buffer[offset..][0..4], .little);
                const gas_limit = std.mem.readInt(u64, always_accumulate_data.buffer[offset + 4 ..][0..8], .little);

                span.debug("Always-accumulate service {d}: ID={d}, gas={d}", .{ k, service_id, gas_limit });

                always_accumulate_services.put(service_id, gas_limit) catch {
                    span.err("Failed to add service to always-accumulate map", .{});
                    return .{ .terminal = .panic };
                };
            }

            var assign_services = std.ArrayList(types.ServiceId).init(ctx_regular.allocator);
            defer assign_services.deinit();

            const assign_memory_size = params.core_count * 4; // Each service ID is 4 bytes
            span.debug("Reading assign service IDs from memory at 0x{x}, size={d} bytes ({d} cores)", .{ assign_ptr, assign_memory_size, params.core_count });

            var assign_data = exec_ctx.memory.readSlice(@truncate(assign_ptr), assign_memory_size) catch {
                span.err("Memory access failed while reading assign service IDs", .{});
                return .{ .terminal = .panic };
            };
            defer assign_data.deinit();

            var i: usize = 0;
            while (i < params.core_count) : (i += 1) {
                const offset = i * 4;
                const service_id = std.mem.readInt(u32, assign_data.buffer[offset..][0..4], .little);

                span.debug("Assign service {d}: ID={d}", .{ i, service_id });

                assign_services.append(service_id) catch {
                    span.err("Failed to add service to assign list", .{});
                    return .{ .terminal = .panic };
                };
            }

            if (exec_ctx.registers[7] > std.math.maxInt(u32) or
                exec_ctx.registers[9] > std.math.maxInt(u32) or
                exec_ctx.registers[10] > std.math.maxInt(u32))
            {
                span.err(
                    "Manager, validator, or registrar service ID exceeds u32 domain. M={d} V={d} R={d}",
                    .{ exec_ctx.registers[7], exec_ctx.registers[9], exec_ctx.registers[10] },
                );
                return HostCallError.WHO;
            }

            const current_privileges: *state.Chi(params.core_count) = ctx_regular.context.privileges.getMutable() catch {
                span.err("Could not get mutable privileges", .{});
                return HostCallError.FULL;
            };

            span.debug("Updating privileges", .{});

            current_privileges.manager = manager_service_id;
            current_privileges.designate = validator_service_id;
            current_privileges.registrar = registrar_service_id;

            std.debug.assert(assign_services.items.len == params.core_count);
            std.debug.assert(current_privileges.assign.len == params.core_count);

            @memcpy(&current_privileges.assign, assign_services.items);

            current_privileges.always_accumulate.clearRetainingCapacity();
            var it = always_accumulate_services.iterator();
            while (it.next()) |entry| {
                current_privileges.always_accumulate.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    span.err("Failed to update always-accumulate services", .{});
                    return .{ .terminal = .panic };
                };
            }

            span.debug("Services blessed successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for upgrade service (Ω_U)
        pub fn upgradeService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_upgrade);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const code_hash_ptr = exec_ctx.registers[7]; // Pointer to new code hash (o)
            const min_gas_limit = exec_ctx.registers[8]; // New gas limit for accumulate (g)
            const min_memo_gas = exec_ctx.registers[9]; // Minimum gas threshold for transfers (m)

            span.debug("Host call: upgrade service {d}", .{ctx_regular.service_id});
            span.debug("Code hash ptr: 0x{x}, Min gas: {d}, Min memo gas: {d}", .{
                code_hash_ptr, min_gas_limit, min_memo_gas,
            });

            span.debug("Reading code hash from memory at 0x{x}", .{code_hash_ptr});
            var code_hash = exec_ctx.memory.readHash(@truncate(code_hash_ptr)) catch {
                span.err("Memory access failed while reading code hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Code hash: {s}", .{std.fmt.fmtSliceHexLower(&code_hash)});

            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Updating service account properties", .{});
            service_account.code_hash = code_hash;
            service_account.min_gas_accumulate = min_gas_limit;
            service_account.min_gas_on_transfer = min_memo_gas;

            span.debug("Service upgraded successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for transfer (Ω_T)
        pub fn transfer(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_transfer);
            defer span.deinit();

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const destination_id = exec_ctx.registers[7]; // Destination service ID
            const amount = exec_ctx.registers[8]; // Amount to transfer
            const gas_limit = exec_ctx.registers[9]; // Gas limit (charged now, refunded after processing)
            const memo_ptr = exec_ctx.registers[10]; // Pointer to memo data

            span.debug("Host call: transfer from service {d} to {d}", .{
                ctx_regular.service_id, destination_id,
            });
            span.debug("Amount: {d}, Gas limit: {d}, Memo ptr: 0x{x}", .{
                amount, gas_limit, memo_ptr,
            });

            span.debug("charging 10 gas (base cost)", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging base cost", .{});
                return .{ .terminal = .out_of_gas };
            }

            span.debug("Reading memo data from memory at 0x{x}", .{memo_ptr});
            var memo_slice = exec_ctx.memory.readSlice(@truncate(memo_ptr), params.transfer_memo_size) catch {
                span.err("Memory access failed while reading memo data (10 gas already charged)", .{});
                return .{ .terminal = .panic };
            };
            defer memo_slice.deinit();

            span.trace("Memo data: {s}", .{std.fmt.fmtSliceHexLower(memo_slice.buffer)});

            span.debug("Looking up destination service account", .{});
            const destination_service = ctx_regular.context.service_accounts.getReadOnly(@intCast(destination_id)) orelse {
                span.debug("Destination service not found, returning WHO error (base 10 gas already charged)", .{});
                return HostCallError.WHO;
            };

            span.debug("Checking gas limit {d} against destination's min threshold: {d}", .{
                gas_limit, destination_service.min_gas_on_transfer,
            });
            if (gas_limit < destination_service.min_gas_on_transfer) {
                span.debug("Gas limit below minimum threshold, returning LOW error", .{});
                return HostCallError.LOW;
            }

            span.debug("Looking up source service account", .{});
            const source_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Source service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            const min_balance = source_service.getStorageFootprint(params).a_t;

            span.debug("Checking source balance {d} - amount {d} = {d} against min_balance {d}", .{
                source_service.balance, amount, source_service.balance -| amount, min_balance,
            });

            if (source_service.balance -| amount < min_balance) {
                span.warn("Transfer would push balance below min_balance threshold, returning CASH error (base 10 gas already charged)", .{});
                return HostCallError.CASH;
            }

            var memo: [params.transfer_memo_size]u8 = [_]u8{0} ** params.transfer_memo_size;
            @memcpy(&memo, memo_slice.buffer[0..params.transfer_memo_size]);

            const transfer_operand = pvm_accumulate.TransferOperand{
                .sender = ctx_regular.service_id,
                .destination = @intCast(destination_id),
                .amount = @intCast(amount),
                .memo = memo,
                .gas_limit = @intCast(gas_limit),
            };

            span.debug("Adding transfer to generated_transfers for next service", .{});
            ctx_regular.generated_transfers.append(transfer_operand) catch {
                return .{ .terminal = .panic };
            };

            span.debug("Deducting {d} from source service balance", .{amount});
            source_service.balance -= @intCast(amount);

            span.debug("charging {d} gas (transfer gas, refunded after processing)", .{gas_limit});
            exec_ctx.gas -= @intCast(gas_limit);

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging transfer gas limit", .{});
                return .{ .terminal = .out_of_gas };
            }

            span.debug("Transfer scheduled successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for assign core (Ω_A)
        pub fn assignCore(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_assign);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const core_index = exec_ctx.registers[7]; // c: Core index to assign
            const output_ptr = exec_ctx.registers[8]; // o: Pointer to authorizer queue data
            const new_assign_service = exec_ctx.registers[9]; // a: New assign service ID

            // IMPORTANT: Check memory accessibility FIRST before validating core index

            span.debug("Reading authorizer hashes from memory at 0x{x}", .{output_ptr});

            const total_size: u32 = 32 * @as(u32, params.max_authorizations_queue_items);

            var hashes_data = exec_ctx.memory.readSlice(@truncate(output_ptr), total_size) catch {
                span.err("Memory access failed while reading authorizer hashes", .{});
                return .{ .terminal = .panic };
            };
            defer hashes_data.deinit();

            if (core_index >= params.core_count) {
                span.debug("Invalid core index {d}, returning CORE error", .{core_index});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.CORE);
                return .play;
            }

            const privileges: *state.Chi(params.core_count) = ctx_regular.context.privileges.getMutable() catch {
                span.err("Problem getting mutable privileges", .{});
                return .{ .terminal = .panic };
            };

            if (ctx_regular.service_id != privileges.assign[core_index]) {
                span.debug("Service {d} is not the assign service for core {d} (current assign: {d}), returning HUH", .{ ctx_regular.service_id, core_index, privileges.assign[core_index] });
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.HUH);
                return .play;
            }

            if (new_assign_service > std.math.maxInt(u32)) {
                span.debug("New assign service ID {d} exceeds u32 range, returning WHO", .{new_assign_service});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.WHO);
                return .play;
            }

            const authorizer_hashes = std.mem.bytesAsSlice(types.AuthorizerHash, hashes_data.buffer);

            for (authorizer_hashes, 0..) |hash, i| {
                span.trace("Authorizer hash {d}: {s}", .{ i, std.fmt.fmtSliceHexLower(&hash) });
            }

            span.debug("Updating authorizer queue for core {d}", .{core_index});
            const auth_queue: *state.Phi(params.core_count, params.max_authorizations_queue_items) = ctx_regular.context.authorizer_queue.getMutable() catch {
                span.err("Problem getting mutable authorizer queue", .{});
                return .{ .terminal = .panic };
            };

            for (0..params.max_authorizations_queue_items) |i| {
                auth_queue.setAuthorization(core_index, i, authorizer_hashes[i]) catch {
                    span.err("Failed to set authorization at index {d} for core {d}", .{ i, core_index });
                    return .{ .terminal = .panic };
                };
            }

            privileges.assign[core_index] = @intCast(new_assign_service);
            span.debug("Updated assign service for core {d} to service {d}", .{ core_index, new_assign_service });

            span.debug("Core assigned successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for checkpoint (Ω_C)
        pub fn checkpoint(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_checkpoint);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));

            span.debug("Host call: checkpoint - cloning regular context to exceptional", .{});

            host_ctx.exceptional.deinit();
            host_ctx.exceptional = host_ctx.regular.deepClone() catch {
                return .{ .terminal = .panic };
            };

            exec_ctx.registers[7] = @intCast(exec_ctx.gas);

            span.debug("Checkpoint created successfully, remaining gas: {d}", .{exec_ctx.gas});
            return .play;
        }

        /// Host call implementation for new service (Ω_N)
        pub fn newService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_new_service);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const code_hash_ptr = exec_ctx.registers[7];
            const code_len_raw = exec_ctx.registers[8];
            const min_gas_limit = exec_ctx.registers[9];
            const min_memo_gas = exec_ctx.registers[10];
            const free_storage_offset = exec_ctx.registers[11];
            const desired_id_raw = exec_ctx.registers[12];

            if (code_len_raw > std.math.maxInt(u32)) {
                span.err("Code length {d} exceeds u32 range, returning PANIC", .{code_len_raw});
                return .{ .terminal = .panic };
            }
            const code_len: u32 = @truncate(code_len_raw);

            span.debug("Host call: new service from service {d}", .{ctx_regular.service_id});
            span.debug("Code hash ptr: 0x{x}, Code len: {d}", .{ code_hash_ptr, code_len });
            span.debug("Min gas limit: {d}, Min memo gas: {d}, Free storage: {d}, Desired ID: {d}", .{ min_gas_limit, min_memo_gas, free_storage_offset, desired_id_raw });

            span.debug("Reading code hash from memory at 0x{x}", .{code_hash_ptr});
            var code_hash = exec_ctx.memory.readHash(@truncate(code_hash_ptr)) catch {
                span.err("Memory access failed while reading code hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Code hash: {s}", .{std.fmt.fmtSliceHexLower(&code_hash)});

            // Get privileges once for both gratis and registrar checks
            const privileges = ctx_regular.context.privileges.getReadOnly();

            if (free_storage_offset != 0) {
                if (ctx_regular.service_id != privileges.manager) {
                    span.debug("Non-manager (service {d}) trying to grant free storage, manager is {d}", .{
                        ctx_regular.service_id, privileges.manager,
                    });
                    return HostCallError.HUH;
                }
                span.debug("Manager granting {d} bytes of free storage", .{free_storage_offset});
            }

            // Determine target service ID - registrar can create services with reserved IDs
            const is_registrar = ctx_regular.service_id == privileges.registrar;
            const desired_id: u32 = @truncate(desired_id_raw);
            const is_reserved_id = desired_id < service_util.C_MIN_PUBLIC_INDEX;

            const target_service_id: u32 = if (is_registrar and is_reserved_id) blk: {
                // Registrar requesting a reserved ID
                if (ctx_regular.context.service_accounts.contains(desired_id)) {
                    span.debug("Registrar requested reserved ID {d} but it already exists, returning FULL", .{desired_id});
                    return HostCallError.FULL;
                }
                span.debug("Registrar creating service with reserved ID: {d}", .{desired_id});
                break :blk desired_id;
            } else blk: {
                // Normal path - use auto-generated ID
                span.debug("Using auto-generated service ID: {d}", .{ctx_regular.new_service_id});
                break :blk ctx_regular.new_service_id;
            };

            // WARN: We need to create the service account first, since there is a
            // chance we are growing the underlying container which could move the items
            // in memory. After we created we are ensured that the getMutable pointer will be valid
            // for as long we are not adding to the container.

            span.debug("Creating new service account with ID: {d}", .{target_service_id});
            var new_account = ctx_regular.context.service_accounts.createService(target_service_id) catch {
                span.err("Failed to create new service account", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Looking up calling service account: {d}", .{ctx_regular.service_id});
            const calling_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Calling service account not found, this should never happen", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Setting new account properties", .{});
            new_account.code_hash = code_hash;
            new_account.min_gas_accumulate = min_gas_limit;
            new_account.min_gas_on_transfer = min_memo_gas;
            new_account.storage_offset = free_storage_offset;
            new_account.parent_service = ctx_regular.service_id;
            new_account.creation_slot = ctx_regular.context.time.current_slot;
            new_account.last_accumulation_slot = 0;
            new_account.balance = 0; // Temporary, will be set after footprint calculation

            span.debug("Integrating preimage lookup", .{});
            new_account.solicitPreimage(target_service_id, code_hash, code_len, ctx_regular.context.time.current_slot) catch {
                span.err("Failed to integrate preimage lookup, out of memory", .{});
                _ = ctx_regular.context.service_accounts.removeService(target_service_id) catch {};
                return .{ .terminal = .panic };
            };

            const footprint = new_account.getStorageFootprint(params);
            const initial_balance = footprint.a_t;

            span.debug("Footprint: items={d}, bytes={d}, threshold={d}", .{
                footprint.a_i, footprint.a_o, footprint.a_t,
            });
            span.debug("Initial balance required: {d}, caller balance: {d}", .{
                initial_balance, calling_service.balance,
            });

            const calling_footprint = calling_service.getStorageFootprint(params);
            if (calling_service.balance -| initial_balance < calling_footprint.a_t) {
                span.debug("Insufficient balance to create new service, under footprint, returning CASH error", .{});
                _ = ctx_regular.context.service_accounts.removeService(target_service_id) catch {};
                return HostCallError.CASH;
            }

            new_account.balance = initial_balance;
            calling_service.balance -= initial_balance;
            span.debug("Set new service balance to {d}, deducted from calling service", .{initial_balance});

            span.debug("Service created successfully, returning service ID: {d}", .{target_service_id});
            exec_ctx.registers[7] = target_service_id;

            // Only update new_service_id for the normal path (not registrar reserved ID case)
            if (!is_registrar or !is_reserved_id) {
                const intermediate_service_id = service_util.C_MIN_PUBLIC_INDEX + ((ctx_regular.new_service_id - service_util.C_MIN_PUBLIC_INDEX + 42) % @as(u32, @intCast(std.math.pow(u64, 2, 32) - service_util.C_MIN_PUBLIC_INDEX - 0x100)));
                ctx_regular.new_service_id = service_util.check(&ctx_regular.context.service_accounts, intermediate_service_id);
            }
            return .play;
        }

        /// Host call implementation for eject service (Ω_J)
        pub fn ejectService(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_eject);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const target_service_id = exec_ctx.registers[7]; // Service ID to eject (d)
            const hash_ptr = exec_ctx.registers[8]; // Hash pointer (o)

            span.debug("Host call: eject service {d}", .{target_service_id});
            span.debug("Hash pointer: 0x{x}", .{hash_ptr});

            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };
            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            if (target_service_id == ctx_regular.service_id) {
                span.debug("Cannot eject current service, returning WHO error", .{});
                return HostCallError.WHO;
            }

            const target_service = ctx_regular.context.service_accounts.getReadOnly(@intCast(target_service_id)) orelse {
                span.debug("Target service not found, returning WHO error", .{});
                return HostCallError.WHO;
            };

            const current_service = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of current service", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Current service not found (should never happen)", .{});
                return .{ .terminal = .panic };
            };

            var e32_service_id = std.mem.zeroes([32]u8);
            std.mem.writeInt(u32, e32_service_id[0..4], @intCast(ctx_regular.service_id), .little);

            const hash_is_e32_service = std.mem.eql(u8, &target_service.code_hash, &e32_service_id);

            if (!hash_is_e32_service) {
                span.debug("Ejection not authorized, returning WHO error", .{});
                span.debug("Current service code hash: {s}", .{std.fmt.fmtSliceHexLower(&current_service.code_hash)});
                span.debug("Target service code hash: {s}", .{std.fmt.fmtSliceHexLower(&target_service.code_hash)});
                span.debug("Provided hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});
                span.debug("E_32(service_id={d}): {s}", .{ ctx_regular.service_id, std.fmt.fmtSliceHexLower(&e32_service_id) });
                return HostCallError.WHO;
            }

            const footprint = target_service.getStorageFootprint(params);

            // Graypaper check order: items != 2 BEFORE request lookup
            // Line 864: d.items ≠ 2 ∨ (h,l) ∉ d.requests (left side evaluated first)
            if (footprint.a_i != 2) {
                span.debug("Service has {} items, expected 2, returning HUH error", .{footprint.a_i});
                return HostCallError.HUH;
            }

            const l = @max(81, footprint.a_o) - 81;
            const lookup_status = target_service.getPreimageLookup(@intCast(target_service_id), hash, @intCast(l)) orelse {
                span.debug("Hash lookup not found, returning HUH error", .{});
                return HostCallError.HUH;
            };

            const current_timeslot = ctx_regular.context.time.current_slot;
            const status = lookup_status.asSlice();

            if (status.len != 2) {
                span.debug("Lookup status length is not 2, returning HUH error", .{});
                return HostCallError.HUH;
            }

            if (status[1].? >= current_timeslot -| params.preimage_expungement_period) {
                span.debug("Preimage not yet expired, returning HUH error", .{});
                return HostCallError.HUH;
            }

            span.debug("Ejecting service {d}", .{target_service_id});

            const target_balance = target_service.balance;

            _ = ctx_regular.context.service_accounts.removeService(@intCast(target_service_id)) catch {
                span.err("Failed to remove service", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Transferring balance {d} from ejected service to current service", .{target_balance});
            current_service.balance += target_balance;

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
            const span = trace.span(@src(), .host_call_query);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const hash_ptr = exec_ctx.registers[7]; // Hash pointer (o)
            const preimage_size = exec_ctx.registers[8]; // Preimage size (z)

            span.debug("Host call: query preimage for service {d}", .{ctx_regular.service_id});
            span.debug("Hash ptr: 0x{x}, Preimage size: {d}", .{ hash_ptr, preimage_size });

            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            span.debug("Getting service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getReadOnly(ctx_regular.service_id) orelse {
                span.err("Service account not found", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Querying preimage status", .{});
            const lookup_status = service_account.getPreimageLookup(ctx_regular.service_id, hash, @intCast(preimage_size)) orelse {
                span.debug("Preimage lookup not found, returning NONE", .{});
                exec_ctx.registers[8] = 0; // Per graypaper: R8 = 0 when lookup doesn't exist
                return HostCallError.NONE;
            };

            var result: u64 = 0;
            var result_high: u64 = 0;

            span.debug("Preimage status found", .{});

            const status = lookup_status.asSlice();

            switch (status.len) {
                0 => {
                    span.debug("Status: requested but not supplied", .{});
                    result = 0;
                    result_high = 0;
                },
                1 => {
                    span.debug("Status: available since time {d}", .{status[0].?});
                    result = 1 + ((@as(u64, status[0].?) << 32));
                    result_high = 0;
                },
                2 => {
                    span.debug("Status: unavailable, was available from {d} until {d}", .{ status[0].?, status[1].? });
                    result = 2 + ((@as(u64, status[0].?) << 32));
                    result_high = status[1].?;
                },
                3 => {
                    span.debug("Status: available since {d}, previously from {d} until {d}", .{ status[2].?, status[0].?, status[1].? });
                    result = 3 + ((@as(u64, status[0].?) << 32));
                    result_high = status[1].? + ((@as(u64, status[2].?) << 32));
                },
                else => {
                    span.err("Invalid preimage status length: {d}", .{status.len});
                    return .{ .terminal = .panic };
                },
            }

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
            const span = trace.span(@src(), .host_call_solicit);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;
            const current_timeslot = ctx_regular.context.time.current_slot;

            const hash_ptr: u32 = @truncate(exec_ctx.registers[7]); // Hash pointer
            const preimage_size: u32 = @truncate(exec_ctx.registers[8]); // Preimage size

            span.debug("Host call: solicit preimage for service {d}", .{ctx_regular.service_id});
            span.debug("Hash ptr: 0x{x}, Preimage size: {d}", .{ hash_ptr, preimage_size });

            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found", .{});
                return HostCallError.HUH;
            };

            span.debug("Attempting to solicit preimage", .{});

            // Check balance for NEW solicitations only
            const existing_lookup = service_account.getPreimageLookup(ctx_regular.service_id, hash, preimage_size);
            if (existing_lookup == null) {
                const additional_storage_size: u64 = 81 +| preimage_size;
                const footprint = service_account.getStorageFootprint(params);
                const storage_cost = params.min_balance_per_octet *| additional_storage_size;
                const additional_balance_needed = params.min_balance_per_item +| storage_cost;

                if (additional_balance_needed > service_account.balance or
                    service_account.balance - additional_balance_needed < footprint.a_t)
                {
                    span.debug("Insufficient balance for new preimage solicitation, returning FULL", .{});
                    return HostCallError.FULL;
                }
                span.debug("Balance check passed for new solicitation", .{});
            }

            // solicitPreimage handles state validation
            if (service_account.solicitPreimage(ctx_regular.service_id, hash, @intCast(preimage_size), current_timeslot)) |_| {
                span.debug("Preimage solicited successfully: {any}", .{service_account.getPreimageLookup(ctx_regular.service_id, hash, preimage_size)});
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            } else |err| {
                switch (err) {
                    error.AlreadySolicited, error.AlreadyAvailable, error.AlreadyReSolicited, error.InvalidState, error.InvalidData => {
                        span.debug("Preimage solicitation failed: {}, returning HUH", .{err});
                        return HostCallError.HUH;
                    },
                    error.OutOfMemory => {
                        span.err("Out of memory while soliciting preimage", .{});
                        return .{ .terminal = .panic };
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
            const span = trace.span(@src(), .host_call_forget);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            var ctx_regular = &host_ctx.regular;
            const current_timeslot = ctx_regular.context.time.current_slot;

            const hash_ptr: u32 = @truncate(exec_ctx.registers[7]);
            const preimage_size: u32 = @truncate(exec_ctx.registers[8]);

            span.debug("Host call: forget preimage", .{});
            span.debug("Hash ptr: 0x{x}, Hash size: {d}", .{ hash_ptr, preimage_size });

            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(hash_ptr) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.trace("Hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            span.debug("Getting mutable service account ID: {d}", .{ctx_regular.service_id});
            const service_account = ctx_regular.context.service_accounts.getMutable(ctx_regular.service_id) catch {
                span.err("Could not get mutable instance of service account", .{});
                return .{ .terminal = .panic };
            } orelse {
                span.err("Service account not found", .{});
                return HostCallError.HUH;
            };

            span.debug("Attempting to forget preimage", .{});
            service_account.forgetPreimage(ctx_regular.service_id, hash, preimage_size, current_timeslot, params.preimage_expungement_period) catch |err| {
                span.err("Error while forgetting preimage: {}", .{err});
                return HostCallError.HUH;
            };

            span.debug("Preimage forgotten successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for yield (Ω_P)
        pub fn yieldAccumulationResult(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_yield);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const hash_ptr = exec_ctx.registers[7];

            span.debug("Host call: yield accumulation result", .{});
            span.debug("Hash pointer: 0x{x}", .{hash_ptr});

            span.debug("Reading hash from memory at 0x{x}", .{hash_ptr});
            const hash = exec_ctx.memory.readHash(@truncate(hash_ptr)) catch {
                span.err("Memory access failed while reading hash", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Accumulation output hash: {s}", .{std.fmt.fmtSliceHexLower(&hash)});

            ctx_regular.accumulation_output = hash;

            span.debug("Yield successful", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for designate validators (Ω_D)
        pub fn designateValidators(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_designate);
            defer span.deinit();

            const VALIDATOR_DATA_SIZE = 336;
            comptime {
                std.debug.assert(@sizeOf(types.ValidatorData) == VALIDATOR_DATA_SIZE);
            }

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const offset_ptr = exec_ctx.registers[7]; // Offset to validator keys array

            span.debug("Host call: designate validators", .{});
            span.debug("Offset pointer: 0x{x}", .{offset_ptr});

            const validator_count: u32 = params.validators_count;
            const total_size: u32 = VALIDATOR_DATA_SIZE * validator_count;

            span.debug("Reading {d} validators, total size: {d} bytes", .{ validator_count, total_size });

            var validator_data = exec_ctx.memory.readSlice(@truncate(offset_ptr), total_size) catch {
                span.err("Memory access failed while reading validator keys", .{});
                return .{ .terminal = .panic };
            };
            defer validator_data.deinit();

            const privileges: *const state.Chi(params.core_count) = ctx_regular.context.privileges.getReadOnly();
            if (privileges.designate != ctx_regular.service_id) {
                span.debug("Service {d} does not have validator privilege, current validator service is {?d}", .{
                    ctx_regular.service_id, privileges.designate,
                });
                exec_ctx.registers[7] = @intFromEnum(ReturnCode.HUH);
                return .play;
            }

            if (validator_data.buffer.len != validator_count * VALIDATOR_DATA_SIZE) {
                span.err("Invalid validator data size: expected {d}, got {d}", .{ validator_count * VALIDATOR_DATA_SIZE, validator_data.buffer.len });
                return .{ .terminal = .panic };
            }

            const validators = std.mem.bytesAsSlice(types.ValidatorData, validator_data.buffer);

            for (validators, 0..) |validator, i| {
                span.trace("Validator {d}: bandersnatch={s}, ed25519={s}", .{
                    i,
                    std.fmt.fmtSliceHexLower(&validator.bandersnatch),
                    std.fmt.fmtSliceHexLower(&validator.ed25519),
                });
            }

            const validator_keys = ctx_regular.context.validator_keys.getMutable() catch {
                span.err("Problem getting mutable validator keys", .{});
                return .{ .terminal = .panic };
            };

            ctx_regular.allocator.free(validator_keys.validators);
            validator_keys.validators = ctx_regular.allocator.dupe(types.ValidatorData, validators) catch {
                span.err("Failed to duplicate validator data", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Updated staging validator set with {d} validators", .{validator_count});

            span.debug("Validators designated successfully", .{});
            exec_ctx.registers[7] = @intFromEnum(ReturnCode.OK);
            return .play;
        }

        /// Host call implementation for provide (Ω_Aries)
        pub fn provide(
            exec_ctx: *PVM.ExecutionContext,
            call_ctx: ?*anyopaque,
        ) HostCallError!PVM.HostCallResult {
            const span = trace.span(@src(), .host_call_provide);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular: *Dimension = &host_ctx.regular;

            const service_id_reg = exec_ctx.registers[7]; // Service ID (s* - can be current service if 2^64-1)
            const data_ptr = exec_ctx.registers[8]; // Data pointer (o)
            const data_size = exec_ctx.registers[9]; // Data size (z)

            span.debug("Host call: provide", .{});
            span.debug("Service ID reg: {d}, data ptr: 0x{x}, data size: {d}", .{ service_id_reg, data_ptr, data_size });

            const service_id: types.ServiceId = host_calls.resolveTargetService(ctx_regular, service_id_reg);

            span.debug("Providing data for service: {d}", .{service_id});

            span.debug("Reading {d} bytes from memory at 0x{x}", .{ data_size, data_ptr });
            var data_slice = exec_ctx.memory.readSlice(@truncate(data_ptr), @truncate(data_size)) catch {
                span.err("Memory access failed while reading provide data", .{});
                return .{ .terminal = .panic };
            };
            defer data_slice.deinit();

            const service_account = ctx_regular.context.service_accounts.getReadOnly(service_id) orelse {
                span.debug("Service {d} not found, returning WHO error", .{service_id});
                return HostCallError.WHO;
            };

            var data_hash: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(data_slice.buffer, &data_hash, .{});

            span.trace("Data hash: {s}", .{std.fmt.fmtSliceHexLower(&data_hash)});

            const lookup = service_account.getPreimageLookup(service_id, data_hash, @intCast(data_size));
            if (lookup == null) {
                span.debug("Preimage not solicited (no lookup exists), returning HUH", .{});
                return HostCallError.HUH;
            }

            const status = lookup.?.asSlice();
            if (status.len != 0) {
                span.debug("Preimage has wrong status (len={d}), only empty status [] allowed, returning HUH", .{status.len});
                return HostCallError.HUH;
            }

            const key = ProvidedKey{
                .service_id = service_id,
                .hash = data_hash,
                .size = @intCast(data_size),
            };
            if (ctx_regular.provided_preimages.contains(key)) {
                span.debug("Preimage already provided in this accumulation, returning HUH", .{});
                return HostCallError.HUH;
            }

            const data_owned = data_slice.takeBufferOwnership(ctx_regular.allocator) catch {
                span.err("Failed to take ownership of data buffer", .{});
                return .{ .terminal = .panic };
            };

            span.debug("Storing provided preimage in context: key={any}", .{key});
            span.trace("Storing provided preimage in context: key={any} data={}", .{ key, std.fmt.fmtSliceHexLower(data_owned) });
            ctx_regular.provided_preimages.put(key, data_owned) catch |err| {
                span.err("Failed to store provided preimage: {}", .{err});
                ctx_regular.allocator.free(data_owned);
                return .{ .terminal = .panic };
            };

            span.debug("Provision stored in context for post-accumulation integration", .{});

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
            const span = trace.span(@src(), .host_call_fetch);
            defer span.deinit();

            span.debug("charging 10 gas", .{});
            exec_ctx.gas -= 10;

            if (exec_ctx.gas < 0) {
                span.debug("Out of gas after charging", .{});
                return .{ .terminal = .out_of_gas };
            }

            const host_ctx: *Context = @ptrCast(@alignCast(call_ctx.?));
            const ctx_regular = &host_ctx.regular;

            const output_ptr = exec_ctx.registers[7]; // Output pointer (o)
            const offset = exec_ctx.registers[8]; // Offset (f)
            const limit = exec_ctx.registers[9]; // Length limit (l)
            const selector = exec_ctx.registers[10]; // Data selector
            const index1: u32 = @truncate(exec_ctx.registers[11]); // Index 1

            span.debug("Host call: fetch selector={d} index1={d}", .{ selector, index1 });
            span.debug("Output ptr: 0x{x}, offset: {d}, limit: {d}", .{ output_ptr, offset, limit });

            var data_to_fetch: ?[]const u8 = null;
            var needs_cleanup = false;

            switch (selector) {
                0 => {
                    span.debug("Encoding JAM chain constants", .{});
                    const encoded_constants = encoding_utils.encodeJamParams(ctx_regular.allocator, params) catch {
                        span.err("Failed to encode JAM chain constants", .{});
                        return HostCallError.NONE;
                    };
                    span.trace("Constants encoded: {s}", .{std.fmt.fmtSliceHexLower(encoded_constants)});
                    data_to_fetch = encoded_constants;
                    needs_cleanup = true;
                },

                1 => {
                    span.debug("Random accumulator available from accumulate context", .{});
                    data_to_fetch = ctx_regular.context.entropy[0..];
                },

                14 => {
                    const combined_data = encoding_utils.encodeCombinedInputs(
                        ctx_regular.allocator,
                        ctx_regular.incoming_transfers,
                        ctx_regular.operands,
                    ) catch {
                        span.err("Failed to encode combined inputs", .{});
                        return HostCallError.NONE;
                    };
                    span.debug("Combined inputs encoded: {d} transfers + {d} work = {d} total", .{
                        ctx_regular.incoming_transfers.len,
                        ctx_regular.operands.len,
                        ctx_regular.incoming_transfers.len + ctx_regular.operands.len,
                    });
                    data_to_fetch = combined_data;
                    needs_cleanup = true;
                },

                15 => {
                    const transfer_count = ctx_regular.incoming_transfers.len;
                    const total_count = transfer_count + ctx_regular.operands.len;

                    if (index1 < total_count) {
                        if (index1 < transfer_count) {
                            const transfer_item = &ctx_regular.incoming_transfers[index1];
                            const transfer_data = encoding_utils.encodeTransferAsInput(ctx_regular.allocator, transfer_item) catch {
                                span.err("Failed to encode transfer input", .{});
                                return HostCallError.NONE;
                            };
                            span.debug("Transfer input encoded: index={d}", .{index1});
                            data_to_fetch = transfer_data;
                            needs_cleanup = true;
                        } else {
                            const operand_index = index1 - transfer_count;
                            const operand = &ctx_regular.operands[operand_index];
                            const operand_data = encoding_utils.encodeOperandTuple(ctx_regular.allocator, operand) catch {
                                span.err("Failed to encode operand tuple", .{});
                                return HostCallError.NONE;
                            };
                            span.debug("Work operand encoded: index={d} (work_index={d})", .{ index1, operand_index });
                            data_to_fetch = operand_data;
                            needs_cleanup = true;
                        }
                    } else {
                        span.debug("Input index out of bounds: index={d}, total={d}", .{ index1, total_count });
                        return HostCallError.NONE;
                    }
                },

                2...13, 16, 17 => {
                    // Selectors 2-13 and 16-17 not available in accumulate context per graypaper
                    // 2-3: Header data (Refine only)
                    // 4-6: Work reports (Refine only)
                    // 7-13: Work package data (Is-Authorized/Refine only)
                    // 16-17: Not defined for accumulate (only selectors 0,1,14,15 valid)
                    span.debug("Selector {d} not available in accumulate context", .{selector});
                    return HostCallError.NONE;
                },

                else => {
                    span.debug("Invalid fetch selector: {d} (valid for accumulate: 0,1,14,15)", .{selector});
                    return HostCallError.NONE;
                },
            }
            defer if (needs_cleanup and data_to_fetch != null) ctx_regular.allocator.free(data_to_fetch.?);

            if (data_to_fetch) |data| {
                const f = @min(offset, data.len);
                const l = @min(limit, data.len - f);

                span.debug("Fetching {d} bytes from offset {d} from data_to_fetch", .{ l, f });

                // TODO: double check this in other memory access patterns
                const v = data[f..][0..l];
                if (v.len == 0) {
                    span.debug("Zero len offset requested, returning size: {d}", .{data.len});
                    exec_ctx.registers[7] = data.len;
                    return .play;
                }

                exec_ctx.memory.writeSlice(@truncate(output_ptr), data[f..][0..l]) catch {
                    span.err("Memory access failed while writing fetch data", .{});
                    return .{ .terminal = .panic };
                };

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
