const messages = @import("messages.zig");

pub const FUZZ_TARGET_VERSION = messages.Version{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub const FUZZ_PROTOCOL_VERSION: u8 = 1;

pub const IMPLEMENTED_FUZZ_FEATURES = messages.FEATURE_FORK | messages.FEATURE_ANCESTRY;

const main_version = @import("../version.zig");
pub const PROTOCOL_VERSION = messages.Version{
    .major = main_version.GRAYPAPER_VERSION.major,
    .minor = main_version.GRAYPAPER_VERSION.minor,
    .patch = main_version.GRAYPAPER_VERSION.patch,
};

pub const TARGET_NAME = "jamzig-target";
