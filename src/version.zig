/// Version information for protocol versioning
pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,
};

pub const GREYPAPER_VERSION = Version{
    .major = 0,
    .minor = 6,
    .patch = 6,
};
