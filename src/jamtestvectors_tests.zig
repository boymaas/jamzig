// JAM Test Vectors Test Registry
// This file contains only JAM test vector tests for faster compilation and focused testing
// Use: zig build test-vectors

// Core test vector tests from jamtestvectors/
comptime {
    // W3F Trace tests
    _ = @import("jamtestvectors.zig");
    
    // Component test vectors
    _ = @import("jamtestvectors/loader.zig");
    _ = @import("jamtestvectors/accumulate.zig");
    _ = @import("jamtestvectors/assurances.zig");
    _ = @import("jamtestvectors/authorizations.zig");
    _ = @import("jamtestvectors/codec.zig");
    _ = @import("jamtestvectors/disputes.zig");
    _ = @import("jamtestvectors/erasure_coding.zig");
    _ = @import("jamtestvectors/fisher_yates.zig");
    _ = @import("jamtestvectors/history.zig");
    _ = @import("jamtestvectors/preimages.zig");
    _ = @import("jamtestvectors/pvm.zig");
    _ = @import("jamtestvectors/safrole.zig");
    _ = @import("jamtestvectors/statistics.zig");
    _ = @import("jamtestvectors/trie.zig");
}

// Implementation tests that use test vectors
comptime {
    _ = @import("accumulate_test.zig");
    _ = @import("assurances_test.zig");
    _ = @import("authorizations_test.zig");
    _ = @import("codec_test.zig");
    _ = @import("disputes_test.zig");
    _ = @import("fisher_yates_test.zig");
    _ = @import("merkle_test.zig");
    _ = @import("preimages_test.zig");
    _ = @import("pvm_test.zig");
    _ = @import("recent_blocks_test.zig");
    _ = @import("reports_test.zig");
    _ = @import("safrole_test.zig");
}