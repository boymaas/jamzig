const std = @import("std");
const pvm_accumulate = @import("../pvm_invocations/accumulate.zig");
const types = @import("../types.zig");
const AccumulationOperand = pvm_accumulate.AccumulationOperand;

pub const ServiceAccumulationOperandsMap = struct {
    map: std.AutoHashMap(types.ServiceId, std.MultiArrayList(Item)),
    allocator: std.mem.Allocator,

    pub const Item = struct { accumulate_gas: types.Gas, operand: AccumulationOperand };

    pub const Operands = struct {
        list_ptr: *const std.MultiArrayList(Item),

        pub const Iterator = struct {
            ma_slice: *const std.MultiArrayList(Item).Slice,
            index: usize,

            pub fn next(self: *Iterator) ?Item {
                if (self.index < self.ma_slice.len) {
                    const item = Item{
                        .accumulate_gas = self.ma_slice.items(.accumulate_gas)[self.index],
                        .operand = self.ma_slice.items(.operand)[self.index],
                    };
                    self.index += 1;
                    return item;
                }
                return null;
            }

            pub fn operands(self: *const Iterator) []const AccumulationOperand {
                const slice = self.ma_slice.slice();
                return slice.items(.operand);
            }

            pub fn reset(self: *Iterator) void {
                self.index = 0;
            }
        };

        pub fn iterator(self: Operands) Iterator {
            return Iterator{
                .ma_slice = self.list_ptr.slice(),
                .index = 0,
            };
        }

        pub fn count(self: Operands) usize {
            return self.list_ptr.len;
        }

        pub fn accumulationOperandSlice(self: Operands) []const AccumulationOperand {
            return self.list_ptr.items(.operand);
        }

        pub fn calcGasLimit(self: Operands) types.Gas {
            var total: types.Gas = 0;
            for (self.list_ptr.items(.accumulate_gas)) |operand_gas_limit| {
                total += operand_gas_limit;
            }
            return total;
        }
    };

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .map = std.AutoHashMap(types.ServiceId, std.MultiArrayList(Item)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addOperand(self: *@This(), service_id: types.ServiceId, operand: Item) !void {
        if (!self.map.contains(service_id)) {
            const empty_list = std.MultiArrayList(Item){};
            try self.map.put(service_id, empty_list);
        }

        var service_operands = self.map.getPtr(service_id).?;
        try service_operands.append(self.allocator, operand);
    }

    pub fn getOperands(self: *const @This(), service_id: types.ServiceId) ?Operands {
        if (self.map.getPtr(service_id)) |operands| {
            return Operands{
                .list_ptr = operands,
            };
        }
        return null;
    }

    pub fn contains(self: *const @This(), service_id: types.ServiceId) bool {
        return self.map.contains(service_id);
    }

    pub fn serviceIdIterator(self: *const @This()) std.AutoHashMap(types.ServiceId, std.MultiArrayList(Item)).KeyIterator {
        return self.map.keyIterator();
    }

    pub fn count(self: *const @This()) usize {
        return self.map.count();
    }

    pub fn deinit(self: *@This()) void {
        var it = self.map.valueIterator();
        while (it.next()) |operands| {
            for (operands.items(.operand)) |*operand| {
                operand.deinit(self.allocator);
            }
            operands.deinit(self.allocator);
        }
        self.map.deinit();
        self.* = undefined;
    }
};
