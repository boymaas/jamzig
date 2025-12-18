/// Version information for protocol versioning
pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,
};

pub const GRAYPAPER_VERSION = Version{
    .major = 0,
    .minor = 7,
    .patch = 2,
};
