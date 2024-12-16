comptime {
    _ = @import("jamtestvectors/loader.zig");
    _ = @import("jamtestvectors/safrole.zig");
    _ = @import("jamtestvectors/codec.zig");
    _ = @import("jamtestvectors/trie.zig");
    _ = @import("jamtestvectors/disputes.zig");
    _ = @import("jamtestvectors/pvm.zig");
    _ = @import("jamtestvectors/history.zig");
    _ = @import("jamtestvectors/erasure_coding.zig");
    _ = @import("jamtestvectors/assurances.zig");

    _ = @import("codec.zig");
    _ = @import("codec_test.zig");
    _ = @import("codec/blob_dict.zig");

    _ = @import("safrole_test.zig");
    _ = @import("safrole_test/diffz.zig");

    _ = @import("ring_vrf_test.zig");

    _ = @import("pvm_test.zig");
    _ = @import("pvm/decoder/immediate.zig");

    _ = @import("merkle.zig");
    _ = @import("merkle_test.zig");

    _ = @import("merkle_binary.zig");
    _ = @import("merkle_mountain_ranges.zig");

    _ = @import("state.zig");
    _ = @import("state_dictionary.zig");
    _ = @import("state_dictionary/reconstruct.zig");
    _ = @import("state_dictionary/delta_reconstruction.zig");
    _ = @import("state_dictionary/delta_reconstruction_test.zig");

    _ = @import("state_merklization.zig");
    _ = @import("state_test.zig");

    _ = @import("state_encoding.zig");
    _ = @import("state_decoding.zig");

    _ = @import("state_format/accumulated_reports.zig"); // TODO: rename to xi
    _ = @import("state_format/authorization.zig"); // TODO: rename to alpha
    _ = @import("state_format/available_reports.zig"); // TODO: rename to theta
    _ = @import("state_format/chi.zig");
    _ = @import("state_format/delta.zig");
    _ = @import("state_format/jam_params.zig");
    _ = @import("state_format/jam_state.zig");
    _ = @import("state_format/phi.zig");
    _ = @import("state_format/pi.zig");
    _ = @import("state_format/psi.zig"); // TODO: rename to psi
    _ = @import("state_format/recent_blocks.zig"); // TODO: rename to beta
    _ = @import("state_format/rho.zig"); // TODO: rename to beta
    _ = @import("state_format/safrole_state.zig"); // TODO: rename to gamma

    _ = @import("services.zig");
    _ = @import("services_priviledged.zig");

    _ = @import("recent_blocks.zig");

    _ = @import("authorization.zig");
    _ = @import("authorization_queue.zig");

    _ = @import("assurances.zig");
    _ = @import("assurances_test.zig");

    _ = @import("disputes.zig");
    _ = @import("disputes_test.zig");

    _ = @import("recent_blocks.zig");
    _ = @import("recent_blocks_test.zig");

    _ = @import("pending_reports.zig");
    _ = @import("available_reports.zig");
    _ = @import("accumulated_reports.zig");

    _ = @import("validator_stats.zig");

    _ = @import("jamtestnet.zig");

    _ = @import("stf_test.zig");
}
