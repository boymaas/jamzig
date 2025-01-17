const std = @import("std");
const testing = std.testing;

const decoder = @import("decoder.zig");
const encoder = @import("encoder.zig");

const InstructionWithArgs = @import("../instruction.zig").InstructionWithArgs;
const InstructionArgs = @import("../instruction.zig").InstructionArgs;
const InstructionType = @import("../instruction.zig").InstructionType;
const InstructionRanges = @import("../instruction.zig").InstructionRanges;

test "encodeInstruction <==> decodeInstruction roundtrip" {
    std.debug.print("Performing roundtrip {{decode,encode}}Instruction\n\n", .{});
    var prng = std.Random.DefaultPrng.init(0);
    var random = prng.random();
    for (0..1_000_000) |_| {
        // Generate a random instruction, please not
        // we do note generate a correct no_of_bytes_to_skip
        var rinst = randomInstruction(&random);

        const encoded = try encoder.encodeInstructionOwned(&rinst);
        const decoded = try decoder.decodeInstruction(encoded.asSlice());

        // set the rinst bytes to skip the same for the comparison, since
        // randomInstruction put this to 0
        rinst.setSkipBytes(decoded.skip_l());

        // std.debug.print("{s} == {s}\r", .{ rinst, decoded });
        try std.testing.expectEqualDeep(rinst, decoded);
    }
}

test " encodeXXXX <==> decodXXX roundtrip tests" {
    var prng = std.Random.DefaultPrng.init(0);
    var random = prng.random();
    inline for (std.meta.fields(InstructionType)) |field| {
        // Get the instruction type name
        var program: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&program);

        const encodeFn = @field(encoder, "encode" ++ field.name);
        const decodeFn = @field(decoder, "decode" ++ field.name);
        const DecodeFnReturnType = @field(InstructionArgs, field.name ++ "Type");

        const PGen = makeParamGenerator(@TypeOf(encodeFn));

        for (0..10_000) |i| {
            std.debug.print("Testing instruction: {s}  ==> iteration {d:>6}\r", .{ field.name, i });
            const encode_fn_params = PGen.generateParams(&random);

            // encode the random params
            fbs.reset();
            _ = try @call(.auto, encodeFn, .{fbs.writer()} ++ encode_fn_params);
            const written = fbs.getWritten();

            // decode
            try verifyInstructionArgs(DecodeFnReturnType, try decodeFn(written), encode_fn_params);
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n\n", .{});
}

pub fn EncodeFnArgsTuple(comptime Function: type) type {
    const info = @typeInfo(Function);
    if (info != .@"fn")
        @compileError("ArgsTuple expects a function type");

    const function_info = info.@"fn";

    var argument_field_list: [function_info.params.len - 1]type = undefined;
    inline for (function_info.params[1..], 0..) |arg, i| {
        const T = arg.type orelse
            @compileError("cannot create ArgsTuple for encoding function with an 'anytype' parameter");
        argument_field_list[i] = T;
    }

    return std.meta.Tuple(&argument_field_list);
}

// This function uses comptime to analyze the encoder function for an instruction type
// and returns a function that can generate appropriate parameters at runtime
fn makeParamGenerator(comptime encodeFn: type) type {
    // Get the encode function for this instruction type (e.g. "encodeNoArgs", "encodeOneImm")
    const EncodeFnArgs = EncodeFnArgsTuple(encodeFn);

    return struct {
        // Function that takes a seed generator and returns properly typed parameters
        pub fn generateParams(random: *std.Random) EncodeFnArgs {
            var params: EncodeFnArgs = undefined;

            // Generate remaining parameters based on their types
            comptime var i = 0;
            inline while (i < std.meta.fields(EncodeFnArgs).len) : (i += 1) {
                const param_type = @TypeOf(params[i]);
                params[i] = switch (comptime param_type) {
                    u8 => random.int(u8), // Register index (0-11)
                    u32 => random.int(u32), // Immediate value
                    u64 => random.int(u64), // Extended Immediate
                    i32 => random.int(i32), // Offset
                    else => @compileError("Unexpected parameter type: " ++ @typeName(param_type)),
                };
            }

            return params;
        }
    };
}

// Helper function to verify registers are within bounds
fn verifyRegisterIndex(decoded: u8, encoded: u8) !void {
    if (decoded != @min(12, encoded & 0x0F)) {
        std.debug.print(
            "Verifying  register index:\n  Decoded:  {d}\n  Encoded: {d}\n",
            .{ decoded, @min(12, encoded & 0x0F) },
        );
        return error.RegisterMismatch;
    }
}

// The instruction encoding is unchanged. Those instructions which previously
// took at most a 32-bit immediate value (like e.g. and_imm) now still can have
// at most a 32-bit physical immediate, however the immediate value is now sign
// extended to full 64-bit before being used.
//
// There's only a single instruction which takes a 64-bit immediate that is
// actually physically encoded in the code stream as 64-bit (load_imm_64)
fn verifyInstructionArgs(
    comptime T: type,
    decoded_args: T,
    encode_params: anytype,
) !void {
    switch (T) {
        InstructionArgs.NoArgsType => {},
        InstructionArgs.OneImmType => {
            const decoded_imm = @as(u32, @truncate(decoded_args.immediate));
            const expected_imm = encode_params[0];
            if (decoded_imm != expected_imm) {
                std.debug.print("Verifying immediate value:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_imm, expected_imm });
                std.debug.print("ERROR: Immediate value mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },
        InstructionArgs.OneRegOneExtImmType => {
            try verifyRegisterIndex(decoded_args.register_index, encode_params[0]);

            if (decoded_args.immediate != encode_params[1]) {
                std.debug.print("Verifying extended immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.immediate, encode_params[1] });
                std.debug.print("ERROR: Extended immediate mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },

        InstructionArgs.TwoImmType => {
            if (@as(u32, @truncate(decoded_args.first_immediate)) != encode_params[0] or
                @as(u32, @truncate(decoded_args.second_immediate)) != encode_params[1])
            {
                std.debug.print("Verifying first immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ @as(u32, @truncate(decoded_args.first_immediate)), encode_params[0] });
                std.debug.print("Verifying second immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ @as(u32, @truncate(decoded_args.second_immediate)), encode_params[1] });
                std.debug.print("ERROR: Immediate values mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },
        InstructionArgs.OneOffsetType => {
            if (decoded_args.offset != encode_params[0]) {
                std.debug.print("Verifying offset:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.offset, encode_params[0] });
                std.debug.print("ERROR: Offset mismatch!\n", .{});
                return error.OffsetMismatch;
            }
        },
        InstructionArgs.OneRegOneImmType => {
            try verifyRegisterIndex(decoded_args.register_index, encode_params[0]);

            if (@as(u32, @truncate(decoded_args.immediate)) != encode_params[1]) {
                std.debug.print("Verifying register index:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.register_index, encode_params[0] });
                std.debug.print("Verifying immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.immediate, encode_params[1] });
                std.debug.print("ERROR: Immediate mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },
        InstructionArgs.OneRegTwoImmType => {
            try verifyRegisterIndex(decoded_args.register_index, encode_params[0]);

            if (@as(u32, @truncate(decoded_args.first_immediate)) != encode_params[1] or
                @as(u32, @truncate(decoded_args.second_immediate)) != encode_params[2])
            {
                std.debug.print("Verifying first immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.first_immediate, encode_params[1] });
                std.debug.print("Verifying second immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.second_immediate, encode_params[2] });
                std.debug.print("ERROR: Immediate values mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },
        InstructionArgs.OneRegOneImmOneOffsetType => {
            try verifyRegisterIndex(decoded_args.register_index, encode_params[0]);

            if (@as(u32, @truncate(decoded_args.immediate)) != encode_params[1] or
                decoded_args.offset != encode_params[2])
            {
                std.debug.print("Verifying register index:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.register_index, encode_params[0] });
                std.debug.print("Verifying immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.immediate, encode_params[1] });
                std.debug.print("Verifying offset:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.offset, encode_params[2] });
                std.debug.print("ERROR: Mixed values mismatch!\n", .{});
                return error.MixedValuesMismatch;
            }
        },
        InstructionArgs.TwoRegType => {
            try verifyRegisterIndex(decoded_args.first_register_index, encode_params[0]);
            try verifyRegisterIndex(decoded_args.second_register_index, encode_params[1]);
        },
        InstructionArgs.TwoRegOneImmType => {
            try verifyRegisterIndex(decoded_args.first_register_index, encode_params[0]);
            try verifyRegisterIndex(decoded_args.second_register_index, encode_params[1]);

            if (@as(u32, @truncate(decoded_args.immediate)) != encode_params[2]) {
                std.debug.print("Verifying immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.immediate, encode_params[2] });
                std.debug.print("ERROR: Immediate mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },
        InstructionArgs.TwoRegOneOffsetType => {
            try verifyRegisterIndex(decoded_args.first_register_index, encode_params[0]);
            try verifyRegisterIndex(decoded_args.second_register_index, encode_params[1]);

            if (decoded_args.offset != encode_params[2]) {
                std.debug.print("Verifying offset:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.offset, encode_params[2] });
                std.debug.print("ERROR: Offset mismatch!\n", .{});
                return error.OffsetMismatch;
            }
        },
        InstructionArgs.TwoRegTwoImmType => {
            try verifyRegisterIndex(decoded_args.first_register_index, encode_params[0]);
            try verifyRegisterIndex(decoded_args.second_register_index, encode_params[1]);

            if (@as(u32, @truncate(decoded_args.first_immediate)) != encode_params[2] or
                @as(u32, @truncate(decoded_args.second_immediate)) != encode_params[3])
            {
                std.debug.print("Verifying first immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.first_immediate, encode_params[2] });
                std.debug.print("Verifying second immediate:\n  Decoded:  {d}\n  Expected: {d}\n", .{ decoded_args.second_immediate, encode_params[3] });
                std.debug.print("ERROR: Immediate values mismatch!\n", .{});
                return error.ImmediateMismatch;
            }
        },
        InstructionArgs.ThreeRegType => {
            try verifyRegisterIndex(decoded_args.first_register_index, encode_params[0]);
            try verifyRegisterIndex(decoded_args.second_register_index, encode_params[1]);
            try verifyRegisterIndex(decoded_args.third_register_index, encode_params[2]);
        },
        else => {
            unreachable;
        },
    }
}

/// Generates a random instruction
pub fn randomInstruction(random: *std.Random) InstructionWithArgs {
    var inst_with_args: InstructionWithArgs = undefined;

    // Select random instruction type (excluding NoArgs which is for terminators)
    const inst_type = @as(InstructionType, @enumFromInt(
        random.intRangeAtMost(u8, 0, std.meta.fields(InstructionType).len - 1),
    ));

    const range = InstructionRanges.get(@tagName(inst_type)).?;
    inst_with_args.instruction = @enumFromInt(random.intRangeAtMost(u8, range.start, range.end));

    inline for (std.meta.fields(InstructionType)) |inst_type_field| {
        if (inst_type == @as(InstructionType, @enumFromInt(inst_type_field.value))) {
            //
            const InstArgs = @FieldType(InstructionArgs, inst_type_field.name);

            var inst_args: InstArgs = undefined;
            inline for (std.meta.fields(InstArgs)) |inst_args_field| {
                @field(inst_args, inst_args_field.name) = switch (inst_args_field.type) {
                    u8 => random.int(u8) % 12, // Register index (0-11)
                    u32 => random.int(u32), // Immediate value
                    // Since immediate values are 32 bit values sign extended to u64
                    // we simulate this by generating the instructions as follows
                    u64 => @bitCast( // bitcast to u64 to get an valid encoded immediat
                        @as(
                            i64, // sign exted to i64
                            @intCast(
                                random.int(i32), // generate a i32 value
                            ),
                        ),
                    ), //  Immediate
                    i32 => random.int(i32), // Offset
                    else => @compileError("Unexpected parameter type for field: " ++ inst_type_field.name ++ " == " ++ @typeName(inst_type_field.type)),
                };
            }
            // NOTE: set to 0 as we did not calculate how much space this thing will be.
            inst_args.no_of_bytes_to_skip = 0;
            inst_with_args.args = @unionInit(InstructionArgs, inst_type_field.name, inst_args);
        }
    }

    return inst_with_args;
}
