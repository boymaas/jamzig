const std = @import("std");
const decoder = @import("../decoder.zig");

pub fn formatInstructionWithArgs(
    self: *const decoder.InstructionWithArgs,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.print("{s}", .{@tagName(self.instruction)});

    switch (self.args) {
        .no_arguments => {},
        .one_immediate => |args| try writer.print(" {d}", .{args.immediate}),
        .one_offset => |args| try writer.print(" {d}", .{args.offset}),
        .one_register_one_immediate => |args| try writer.print(" r{d}, {d}", .{ args.register_index, args.immediate }),
        .one_register_one_immediate_one_offset => |args| try writer.print(" r{d}, {d}, {d}", .{ args.register_index, args.immediate, args.offset }),
        .one_register_one_extended_immediate => |args| try writer.print(" r{d}, {d}", .{ args.register_index, args.immediate }),
        .one_register_two_immediates => |args| try writer.print(" r{d}, {d}, {d}", .{ args.register_index, args.first_immediate, args.second_immediate }),
        .three_registers => |args| try writer.print(" r{d}, r{d}, r{d}", .{ args.first_register_index, args.second_register_index, args.third_register_index }),
        .two_immediates => |args| try writer.print(" {d}, {d}", .{ args.first_immediate, args.second_immediate }),
        .two_registers => |args| try writer.print(" r{d}, r{d}", .{ args.first_register_index, args.second_register_index }),
        .two_registers_one_immediate => |args| try writer.print(" r{d}, r{d}, {d}", .{ args.first_register_index, args.second_register_index, args.immediate }),
        .two_registers_one_offset => |args| try writer.print(" r{d}, r{d}, {d}", .{ args.first_register_index, args.second_register_index, args.offset }),
        .two_registers_two_immediates => |args| try writer.print(" r{d}, r{d}, {d}, {d}", .{ args.first_register_index, args.second_register_index, args.first_immediate, args.second_immediate }),
    }
}
