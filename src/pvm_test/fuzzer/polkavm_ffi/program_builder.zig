const std = @import("std");

pub const ProgramBuilder = struct {
    allocator: std.mem.Allocator,
    ro_data: []const u8,
    rw_data: []const u8,
    code: []const u8,
    jump_table: []const u32,
    bitmask: []const u8,
    exports: []const u8,
    import_offsets: []const u8,
    import_symbols: []const u8,
    debug_strings: []const u8,
    debug_line_programs: []const u8,
    debug_line_ranges: []const u8,
    is_64_bit: bool,
    stack_size: u32,

    pub const Config = struct {
        is_64_bit: bool = true,
        stack_size: u32 = 4096,
    };

    // A helper struct to write sections of data with proper length prefixing
    pub const SectionWriter = struct {
        buffer: std.ArrayList(u8),

        /// Initialize a new section with the given section index
        pub fn init(allocator: std.mem.Allocator) !SectionWriter {
            return .{
                .buffer = std.ArrayList(u8).init(allocator),
            };
        }

        /// Get the writer interface for writing section data
        pub fn writer(self: *SectionWriter) std.ArrayList(u8).Writer {
            return self.buffer.writer();
        }

        /// Finish writing the section by calculating and writing the actual length
        pub fn finish(self: *SectionWriter, section_idx: u8, wrtr: anytype) !void {
            try wrtr.writeByte(section_idx);
            try writeVarInt(wrtr, @intCast(self.buffer.items.len));
            _ = try wrtr.write(self.buffer.items);
        }

        pub fn deinit(self: *SectionWriter) void {
            self.buffer.deinit();
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        code: []const u8,
        bitmask: []const u8,
        jump_table: []const u32,
        ro_data: []const u8,
        rw_data: []const u8,
        config: Config,
    ) ProgramBuilder {
        return .{
            .allocator = allocator,
            .code = code,
            .bitmask = bitmask,
            .jump_table = jump_table,
            .ro_data = ro_data,
            .rw_data = rw_data,
            .exports = &[_]u8{},
            .import_offsets = &[_]u8{},
            .import_symbols = &[_]u8{},
            .debug_strings = &[_]u8{},
            .debug_line_programs = &[_]u8{},
            .debug_line_ranges = &[_]u8{},
            .is_64_bit = config.is_64_bit,
            .stack_size = config.stack_size,
        };
    }

    pub fn build(self: *const ProgramBuilder) ![]u8 {
        var blob = std.ArrayList(u8).init(self.allocator);
        errdefer blob.deinit();

        // Magic bytes
        try blob.appendSlice("PVM\x00");

        // Version - 0 for 64-bit, 1 for 32-bit
        try blob.append(if (self.is_64_bit) @as(u8, 0) else @as(u8, 1));

        // Length placeholder
        const len_pos = blob.items.len;
        try blob.appendSlice(&[_]u8{0} ** 8);

        { // Memory Config
            var memory_config = try SectionWriter.init(self.allocator);
            defer memory_config.deinit();

            try writeVarInt(memory_config.writer(), @intCast(self.ro_data.len));
            try writeVarInt(memory_config.writer(), @intCast(self.rw_data.len));
            try writeVarInt(memory_config.writer(), self.stack_size);

            try memory_config.finish(1, blob.writer());
        }

        // RO data section
        try blob.append(2); // SECTION_RO_DATA
        try writeVarInt(blob.writer(), @intCast(self.ro_data.len));
        try blob.appendSlice(self.ro_data);

        // RW data section
        try blob.append(3); // SECTION_RW_DATA
        try writeVarInt(blob.writer(), @intCast(self.rw_data.len));
        try blob.appendSlice(self.rw_data);

        // Import section (if any imports exist)
        // We ignore these nothing written here

        // Export section (if any)
        // We ignore these

        // Code and jump table section
        {
            // Code and jump table section
            var code_section = try SectionWriter.init(self.allocator);
            defer code_section.deinit();

            try writeVarInt(code_section.writer(), @intCast(self.jump_table.len)); // jump table entries
            try code_section.writer().writeByte(4); // jump table entry size
            try writeVarInt(code_section.writer(), @intCast(self.code.len));

            for (self.jump_table) |entry| {
                try code_section.writer().writeInt(u32, entry, .little);
            }
            try code_section.writer().writeAll(self.code);
            try code_section.writer().writeAll(self.bitmask);

            try code_section.finish(6, blob.writer()); // SECTION_CODE_AND_JUMP_TABLE
        }

        // Debug sections if present
        // Ignore

        // End of file
        try blob.append(0); // SECTION_END_OF_FILE

        // Fill in total length
        const total_len = blob.items.len;
        std.mem.writeInt(
            u64,
            blob.items[len_pos..][0..8],
            @intCast(total_len),
            .little,
        );

        return blob.toOwnedSlice();
    }

    // Helper to set debug info
    pub fn setDebugInfo(
        self: *ProgramBuilder,
        strings: []const u8,
        programs: []const u8,
        ranges: []const u8,
    ) void {
        self.debug_strings = strings;
        self.debug_line_programs = programs;
        self.debug_line_ranges = ranges;
    }

    // Helper to set import info
    pub fn setImports(
        self: *ProgramBuilder,
        offsets: []const u8,
        symbols: []const u8,
    ) void {
        self.import_offsets = offsets;
        self.import_symbols = symbols;
    }

    // Helper to set exports
    pub fn setExports(self: *ProgramBuilder, exports: []const u8) void {
        self.exports = exports;
    }
};

// Helper function to determine the length of a varint based on leading zeros
inline fn getVarintLength(leading_zeros: u32) u32 {
    const bits_required = 32 - leading_zeros;
    const x = bits_required >> 3;
    return ((x + bits_required) ^ x) >> 3;
}

// Writes a varint to a buffer and returns the number of bytes written
fn writeVarInt(writer: anytype, value: u32) !void {
    const varint_length = getVarintLength(@clz(value));

    var value_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &value_bytes, value, .little);

    var buffer: [5]u8 = undefined;
    switch (varint_length) {
        0 => buffer[0] = @truncate(value),
        1 => {
            buffer[0] = 0b10000000 | @as(u8, @truncate(value >> 8));
            buffer[1] = value_bytes[0];
        },
        2 => {
            buffer[0] = 0b11000000 | @as(u8, @truncate(value >> 16));
            buffer[1] = value_bytes[0];
            buffer[2] = value_bytes[1];
        },
        3 => {
            buffer[0] = 0b11100000 | @as(u8, @truncate(value >> 24));
            buffer[1] = value_bytes[0];
            buffer[2] = value_bytes[1];
            buffer[3] = value_bytes[2];
        },
        4 => {
            buffer[0] = 0b11110000;
            buffer[1] = value_bytes[0];
            buffer[2] = value_bytes[1];
            buffer[3] = value_bytes[2];
            buffer[4] = value_bytes[3];
        },
        else => unreachable,
    }

    _ = try writer.write(buffer[0 .. varint_length + 1]);
}
