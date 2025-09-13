const messages = @import("messages.zig");

/// Version information for the fuzz protocol target
pub const FUZZ_TARGET_VERSION = messages.Version{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

/// Fuzz protocol version (v1)
pub const FUZZ_PROTOCOL_VERSION: u8 = 1;

/// Default supported features for this implementation
pub const DEFAULT_FUZZ_FEATURES = messages.FEATURE_ANCESTRY | messages.FEATURE_FORK;

/// Protocol version supported by this implementation
const main_version = @import("../version.zig");
pub const PROTOCOL_VERSION = messages.Version{
    .major = main_version.GRAYPAPER_VERSION.major,
    .minor = main_version.GRAYPAPER_VERSION.minor,
    .patch = main_version.GRAYPAPER_VERSION.patch,
};

/// Name of the fuzz protocol target
pub const TARGET_NAME = "jamzig-target";

