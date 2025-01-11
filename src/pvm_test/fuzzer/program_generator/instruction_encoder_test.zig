const std = @import("std");
const testing = std.testing;

const decoder = @import("../../../pvm/decoder.zig");
const encoder = @import("instruction_encoder.zig");
const SeedGenerator = @import("../seed.zig").SeedGenerator;

const InstructionType = @import("instruction.zig").InstructionType;
const InstructionRanges = @import("instruction.zig").InstructionRanges;

test "instruction encoding <==> decoding roundtrip tests" {
    var seed = SeedGenerator.init(0);
    inline for (std.meta.fields(InstructionType)) |field| {
        // Get the instruction type name
        const type_name = field.name;
        // Get the range for this type
        const range = comptime InstructionRanges.get(type_name).?;

        // Test each opcode in the range
        comptime var opcode = range.start;
        inline while (opcode <= range.end) : (opcode += 1) {
            // Here we'll add the encode/decode test logic

            var program: [16]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&program);
            var enc = encoder.buildEncoder(fbs.writer());

            // const encodeFn = @FieldType(@TypeOf(enc), "encode" ++ field.name);
            const encodeFn = @field(@TypeOf(enc), "encode" ++ field.name);
            const paramGenerator = makeParamGenerator(@TypeOf(enc), field.name);

            std.debug.print("\nTesting {s} (opcode: {d})\n", .{ type_name, opcode });

            for (0..5_000) |i| {
                var encodeFnParams = paramGenerator.generateParams(&seed);

                // std.debug.print("{any}", .{encodeFnParams});

                // encode the random params
                fbs.reset();
                encodeFnParams[0] = &enc;
                const length = try @call(.auto, encodeFn, encodeFnParams);
                _ = try enc.encodeNoArgs(1);
                const written = fbs.getWritten();

                // create a mask based on the returned length
                var mask: [16]u8 = std.mem.zeroes([16]u8);
                mask[length / 8] |= @as(u8, 0x01) << @intCast(length % 8);

                // decode
                const dec = decoder.Decoder.init(written, &mask);
                const instruction = try dec.decodeInstruction(0);

                std.debug.print("{d:0<6} ==> {s}\r", .{ i, instruction });
            }
        }
    }
    std.debug.print("\n\n", .{});
}

// This function uses comptime to analyze the encoder function for an instruction type
// and returns a function that can generate appropriate parameters at runtime
fn makeParamGenerator(comptime enc: type, comptime instruction_type: []const u8) type {
    // Get the encode function for this instruction type (e.g. "encodeNoArgs", "encodeOneImm")
    const encodeFn = @field(enc, "encode" ++ instruction_type);
    const EncodeFnParams = std.meta.ArgsTuple(@TypeOf(encodeFn));

    return struct {
        // Function that takes a seed generator and returns properly typed parameters
        pub fn generateParams(seed_gen: *SeedGenerator) EncodeFnParams {
            var params: EncodeFnParams = undefined;
            const range = InstructionRanges.get(instruction_type).?;

            // First param is always the encoder reference
            params[0] = undefined; // Will be filled in at runtime

            // Second param is always the opcode
            params[1] = seed_gen.randomIntRange(u8, range.start, range.end);

            // Generate remaining parameters based on their types
            comptime var i = 2;
            inline while (i < std.meta.fields(EncodeFnParams).len) : (i += 1) {
                const param_type = @TypeOf(params[i]);
                params[i] = switch (param_type) {
                    u8 => seed_gen.randomIntRange(u8, 0, 11), // Register index (0-11)
                    u32 => seed_gen.randomImmediate(), // Immediate value
                    i32 => @bitCast(seed_gen.randomImmediate()), // Offset
                    else => @compileError("Unexpected parameter type: " ++ @typeName(param_type)),
                };
            }

            return params;
        }

        // Helper function to get the parameter types for debugging/validation
        pub fn getParamTypes() []const type {
            comptime {
                var types: []const type = &.{};
                var i = 0;
                while (i < std.meta.fields(EncodeFnParams).len) : (i += 1) {
                    types = types ++ &[_]type{@TypeOf(@field(EncodeFnParams, std.fmt.comptimePrint("{d}", .{i})))};
                }
                return types;
            }
        }
    };
}
