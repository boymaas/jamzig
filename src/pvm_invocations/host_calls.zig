/// Enum representing all possible host call operations
pub const Id = enum(u32) {
    gas = 0, // Host call for retrieving remaining gas counter
    fetch = 1, // Host call for fetching work packages
    lookup = 2, // Host call for looking up preimages by hash
    read = 3, // Host call for reading from service storage
    write = 4, // Host call for writing to service storage
    info = 5, // Host call for obtaining service account information
    historical_lookup = 6, // Host call for looking up historical state
    // Refine hostcalls
    @"export" = 7, // Host call for exporting data to data lake
    machine = 8, // Host call for accessing machine information
    peek = 9, // Host call for reading from data lake
    poke = 10, // Host call for writing to data lake
    pages = 11, // Host call for managing memory pages
    invoke = 12, // Host call for invoking another service
    expunge = 13, // Host call for removing data from data lake
    // Accumulate hostcalls
    bless = 14, // Host call for empowering a service with privileges
    assign = 15, // Host call for assigning cores to validators
    designate = 16, // Host call for designating validator keys for the next epoch
    checkpoint = 17, // Host call for creating a checkpoint of state
    new = 18, // Host call for creating a new service account
    upgrade = 19, // Host call for upgrading service code
    transfer = 20, // Host call for transferring balance between services
    eject = 21, // Host call for ejecting/removing a service
    query = 22, // Host call for querying preimage status
    solicit = 23, // Host call for soliciting a preimage
    forget = 24, // Host call for forgetting/removing a preimage
    yield = 25, // Host call for yielding accumulation trie result
    provide = 26, // Host call for providing data to accumulation
    // Note: zero (23) and void (24) from v0.6.6 are no longer present in v0.6.7
    // Logging
    log = 100, // Host call for logging
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
