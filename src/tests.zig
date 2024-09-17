comptime {
    _ = @import("codec.zig");
    _ = @import("codec_test.zig");
    _ = @import("tests/vectors/codec.zig");

    _ = @import("safrole_test.zig");
    _ = @import("safrole/types_test.zig");
    _ = @import("safrole_test/diffz.zig");

    _ = @import("crypto.zig");
}

pub const tv_types = @import("tests/vectors/libs/types.zig");

pub const hexStringToBytes = tv_types.hex.hexStringToBytes;

// Safrole
pub const convert = @import("tests/convert/safrole.zig");
pub const stateFromTestVector = convert.stateFromTestVector;
pub const inputFromTestVector = convert.inputFromTestVector;
pub const outputFromTestVector = convert.outputFromTestVector;
