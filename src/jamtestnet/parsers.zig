pub const bin = struct {
    pub const traces = @import("parsers/bin/traces.zig");
    pub const genesis = @import("parsers/bin/genesis.zig");
};

pub const json = struct {
    pub const traces = @import("parsers/json/traces.zig");
    pub const genesis = @import("parsers/json/genesis.zig");
};
