/// Enum representing all possible host call operations
pub const Id = enum(u32) {
    gas = 0, // Host call for retrieving remaining gas counter
    lookup = 1, // Host call for looking up preimages by hash
    read = 2, // Host call for reading from service storage
    write = 3, // Host call for writing to service storage
    info = 4, // Host call for obtaining service account information
    bless = 5, // Host call for empowering a service with privileges
    assign = 6, // Host call for assigning cores to validators
    designate = 7, // Host call for designating validator keys for the next epoch
    checkpoint = 8, // Host call for creating a checkpoint of state
    new = 9, // Host call for creating a new service account
    upgrade = 10, // Host call for upgrading service code
    transfer = 11, // Host call for transferring balance between services
    eject = 12, // Host call for ejecting/removing a service
    query = 13, // Host call for querying preimage status
    solicit = 14, // Host call for soliciting a preimage
    forget = 15, // Host call for forgetting/removing a preimage
    yield = 16, // Host call for yielding accumulation trie result
};

/// Return codes for host call operations
pub const ReturnCode = enum(u64) {
    OK = 0, // The return value indicating general success
    NONE = 0xFFFFFFFFFFFFFFFF, // The return value indicating an item does not exist (2^64 - 1)
    WHAT = 0xFFFFFFFFFFFFFFFE, // Name unknown (2^64 - 2)
    OOB = 0xFFFFFFFFFFFFFFFD, // The inner pvm memory index provided for reading/writing is not accessible (2^64 - 3)
    WHO = 0xFFFFFFFFFFFFFFFC, // Index unknown (2^64 - 4)
    FULL = 0xFFFFFFFFFFFFFFFB, // Storage full (2^64 - 5)
    CORE = 0xFFFFFFFFFFFFFFFA, // Core index unknown (2^64 - 6)
    CASH = 0xFFFFFFFFFFFFFFF9, // Insufficient funds (2^64 - 7)
    LOW = 0xFFFFFFFFFFFFFFF8, // Gas limit too low (2^64 - 8)
    HUH = 0xFFFFFFFFFFFFFFF7, // The item is already solicited or cannot be forgotten (2^64 - 9)
};
