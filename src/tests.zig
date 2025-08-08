comptime {
    _ = @import("itertools.zig");

    _ = @import("jamtestvectors/loader.zig");
    _ = @import("jamtestvectors/safrole.zig");
    _ = @import("jamtestvectors/codec.zig");
    _ = @import("jamtestvectors/trie.zig");
    _ = @import("jamtestvectors/disputes.zig");
    _ = @import("jamtestvectors/pvm.zig");
    _ = @import("jamtestvectors/history.zig");
    _ = @import("jamtestvectors/erasure_coding.zig");
    _ = @import("jamtestvectors/assurances.zig");
    _ = @import("jamtestvectors/fisher_yates.zig");
    _ = @import("jamtestvectors/authorizations.zig");
    _ = @import("jamtestvectors/accumulate.zig");
    _ = @import("jamtestvectors/preimages.zig");
    _ = @import("jamtestvectors/statistics.zig");

    _ = @import("codec.zig");
    _ = @import("codec_test.zig");

    _ = @import("fisher_yates.zig");
    _ = @import("fisher_yates_test.zig");

    _ = @import("guarantor_assignments.zig");
    _ = @import("guarantor_assignments_test.zig");

    _ = @import("safrole_test.zig");

    _ = @import("ring_vrf_test.zig");

    _ = @import("pvm/instruction/codec_test.zig");
    _ = @import("pvm/instruction/immediate.zig");
    _ = @import("pvm/decoder.zig");

    _ = @import("pvm_test.zig");
    _ = @import("pvm_fuzz_test.zig");
    _ = @import("pvm_test/fuzzer/test.zig");
    _ = @import("pvm_test/fuzzer/program_generator.zig");
    _ = @import("pvm_test/fuzzer/polkavm_ffi.zig");

    _ = @import("pvm_invocations/accumulate.zig");
    _ = @import("pvm_invocations/ontransfer.zig");

    _ = @import("merkle.zig");
    _ = @import("merkle_test.zig");

    _ = @import("merkle/binary.zig");
    _ = @import("merkle/mmr.zig");

    _ = @import("state.zig");
    _ = @import("state_dictionary.zig");
    _ = @import("state_dictionary/reconstruct.zig");
    _ = @import("state_dictionary/delta_reconstruction.zig");
    _ = @import("state_dictionary/delta_reconstruction_test.zig");

    _ = @import("state_merklization.zig");
    _ = @import("state_test.zig");
    _ = @import("state_random_generator.zig");
    _ = @import("state_merklization_roundtrip_test.zig");

    _ = @import("state_encoding.zig");
    _ = @import("state_decoding.zig");

    _ = @import("services.zig");
    _ = @import("services_snapshot.zig");
    _ = @import("services_priviledged.zig");

    _ = @import("state_keys.zig");
    _ = @import("state_recovery.zig");

    _ = @import("recent_blocks.zig");

    _ = @import("authorizations.zig");
    _ = @import("authorizations_test.zig");

    _ = @import("authorizer_pool.zig");
    _ = @import("authorizer_queue.zig");

    _ = @import("assurances.zig");
    _ = @import("assurances_test.zig");

    _ = @import("reports.zig");
    _ = @import("reports_test.zig");

    _ = @import("disputes.zig");
    _ = @import("disputes_test.zig");

    _ = @import("recent_blocks.zig");
    _ = @import("recent_blocks_test.zig");

    _ = @import("reports_pending.zig");
    _ = @import("reports_ready.zig");
    _ = @import("reports_accumulated.zig");

    _ = @import("validator_stats.zig");

    _ = @import("accumulate.zig");
    _ = @import("accumulate_test.zig");

    _ = @import("header_validator.zig");

    _ = @import("preimages.zig");
    _ = @import("preimages_test.zig");

    _ = @import("jamtestnet.zig");
    // Removed import for jamduna parser - now using only W3F format

    _ = @import("stf_test.zig");

    _ = @import("crypto/bandersnatch.zig");
    _ = @import("crypto/bls12_381.zig");

    // Data structures
    _ = @import("datastruct/hash_set.zig");

    // Networking
    _ = @import("net/tests.zig");

    // Fuzz Protocol
    _ = @import("fuzz_protocol/tests.zig");

    // Proof of Concepts
    _ = @import("lab/thread/reactor_pattern.zig");
}
