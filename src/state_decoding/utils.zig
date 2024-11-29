const decoder = @import("../codec/decoder.zig");
const util = @import("../codec/util.zig");

pub fn readInteger(reader: anytype) !u64 {
    // Read first byte
    const first_byte = try reader.readByte();

    if (first_byte == 0) {
        return 0;
    }

    if (first_byte < 0x80) {
        return first_byte;
    }

    if (first_byte == 0xff) {
        // Special case: 8-byte fixed-length integer
        var buf: [8]u8 = undefined;
        const bytes_read = try reader.readAll(&buf);
        if (bytes_read != 8) {
            return error.EndOfStream;
        }
        return decoder.decodeFixedLengthInteger(u64, &buf);
    }

    const dl = util.decode_prefix(first_byte);

    // Read the remaining bytes
    var buf: [8]u8 = undefined;
    const bytes_read = try reader.readAll(buf[0..dl.l]);
    if (bytes_read != dl.l) {
        return error.InsufficientData;
    }

    const remainder = decoder.decodeFixedLengthInteger(u64, buf[0..dl.l]);
    return remainder + dl.integer_multiple;
}
