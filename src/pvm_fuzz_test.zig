const std = @import("std");
const pvmlib = @import("pvm.zig");

const polkavm = @import("pvm_fuzz_test/polkavm.zig");

// Reference tests
comptime {
    _ = @import("pvm_fuzz_test/polkavm.zig");
}
