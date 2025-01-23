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
        .NoArgs => {},
        .OneImm => |args| try writer.print(" 0x{x}", .{args.immediate}),
        .OneOffset => |args| try writer.print(" {d}", .{args.offset}),
        .OneRegOneImm => |args| try writer.print(" r{d}, 0x{x}", .{ args.register_index, args.immediate }),
        .OneRegOneImmOneOffset => |args| try writer.print(" r{d}, 0x{x}, {d}", .{ args.register_index, args.immediate, args.offset }),
        .OneRegOneExtImm => |args| try writer.print(" r{d}, 0x{x}", .{ args.register_index, args.immediate }),
        .OneRegTwoImm => |args| try writer.print(" r{d}, 0x{x}, 0x{x}", .{ args.register_index, args.first_immediate, args.second_immediate }),
        .ThreeReg => |args| try writer.print(" r{d}, r{d}, r{d}", .{ args.first_register_index, args.second_register_index, args.third_register_index }),
        .TwoImm => |args| try writer.print(" 0x{x}, 0x{x}", .{ args.first_immediate, args.second_immediate }),
        .TwoReg => |args| try writer.print(" r{d}, r{d}", .{ args.first_register_index, args.second_register_index }),
        .TwoRegOneImm => |args| try writer.print(" r{d}, r{d}, 0x{x}", .{ args.first_register_index, args.second_register_index, args.immediate }),
        .TwoRegOneOffset => |args| try writer.print(" r{d}, r{d}, {d}", .{ args.first_register_index, args.second_register_index, args.offset }),
        .TwoRegTwoImm => |args| try writer.print(" r{d}, r{d}, 0x{x}, 0x{x}", .{ args.first_register_index, args.second_register_index, args.first_immediate, args.second_immediate }),
    }
}
