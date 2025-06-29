const messages = @import("messages.zig");

/// Version information for the fuzz protocol target
pub const FUZZ_TARGET_VERSION = messages.Version{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

/// Protocol version supported by this implementation
const GREYPAPER_VERSION = @import("../version.zig");
pub const PROTOCOL_VERSION = messages.Version{
    .major = GREYPAPER_VERSION.major,
    .minor = GREYPAPER_VERSION.minor,
    .patch = GREYPAPER_VERSION.patch,
};

/// Name of the fuzz protocol target
pub const TARGET_NAME = "jamzig-target";

