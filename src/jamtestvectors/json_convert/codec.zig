const std = @import("std");
const tv_types = @import("../json_types/types.zig");
const tv_lib_codec = @import("../json_types/codec.zig");

const lib_codec = @import("../../types.zig");

const Allocator = std.mem.Allocator;

pub const generic = @import("generic.zig");

/// Mapping between types in the test vector and the codec.
const TypeMapping = struct {
    pub fn HexBytes(allocator: Allocator, from: tv_types.hex.HexBytes) ![]u8 {
        return try allocator.dupe(u8, from.bytes);
    }
    pub fn @"HexBytesFixed(32)"(from: tv_types.hex.HexBytesFixed(32)) [32]u8 {
        return convertHexBytesFixedToArray(32, from);
    }

    pub fn @"HexBytesFixed(64)"(from: tv_types.hex.HexBytesFixed(64)) [64]u8 {
        return convertHexBytesFixedToArray(64, from);
    }

    pub fn @"HexBytesFixed(96)"(from: tv_types.hex.HexBytesFixed(96)) [96]u8 {
        return convertHexBytesFixedToArray(96, from);
    }

    pub fn @"HexBytesFixed(784)"(from: tv_types.hex.HexBytesFixed(784)) [784]u8 {
        return convertHexBytesFixedToArray(784, from);
    }

    pub fn TicketBody(allocator: Allocator, from: []const tv_lib_codec.TicketBody) !lib_codec.TicketsMark {
        var tickets = try allocator.alloc(lib_codec.TicketBody, from.len);
        for (from, 0..) |ticket, i| {
            tickets[i] = convertTicketBody(ticket);
        }
        return lib_codec.TicketsMark{ .tickets = tickets };
    }
    pub fn WorkExecResult(allocator: Allocator, from: tv_lib_codec.WorkExecResult) !lib_codec.WorkExecResult {
        return switch (from) {
            .ok => |ok| lib_codec.WorkExecResult{ .ok = try allocator.dupe(u8, ok.bytes) },
            .out_of_gas => lib_codec.WorkExecResult.out_of_gas,
            .panic => lib_codec.WorkExecResult.panic,
            .bad_code => lib_codec.WorkExecResult.bad_code,
            .code_oversize => lib_codec.WorkExecResult.code_oversize,
        };
    }
    pub fn AvailAssurance(allocator: Allocator, from: []const tv_lib_codec.AvailAssurance) !lib_codec.AssurancesExtrinsic {
        var e: lib_codec.AssurancesExtrinsic = undefined;
        e.data = try allocator.alloc(lib_codec.AvailAssurance, from.len);
        for (from, e.data) |fr, *to| {
            to.* = try convertAvailAssurance(allocator, fr);
        }
        return e;
    }
    pub fn ReportGuarantee(allocator: Allocator, from: []const tv_lib_codec.ReportGuarantee) !lib_codec.GuaranteesExtrinsic {
        var e: lib_codec.GuaranteesExtrinsic = undefined;
        e.data = try allocator.alloc(lib_codec.ReportGuarantee, from.len);
        for (from, e.data) |fr, *to| {
            to.* = try convertReportGuarantee(allocator, fr);
        }
        return e;
    }
    pub fn Preimage(allocator: Allocator, from: []const tv_lib_codec.Preimage) !lib_codec.PreimagesExtrinsic {
        var e: lib_codec.PreimagesExtrinsic = undefined;
        e.data = try allocator.alloc(lib_codec.Preimage, from.len);
        for (from, e.data) |fr, *to| {
            to.* = try convertPreimage(allocator, fr);
        }
        return e;
    }

    pub fn TicketEnvelope(allocator: Allocator, from: []const tv_lib_codec.TicketEnvelope) !lib_codec.TicketsExtrinsic {
        var e: lib_codec.TicketsExtrinsic = undefined;
        e.data = try allocator.alloc(lib_codec.TicketEnvelope, from.len);
        for (from, e.data) |fr, *to| {
            to.* = convertTicketEnvelope(fr);
        }
        return e;
    }

    pub fn WorkReport(allocator: Allocator, from: tv_lib_codec.WorkReport) !lib_codec.WorkReport {
        return try convertWorkReport(allocator, from);
    }
};

/// Convert a `testvecor.Header` to a `codec.Header`.
pub fn convertHeader(allocator: Allocator, from: tv_lib_codec.Header) !lib_codec.Header {
    return try generic.convert(lib_codec.Header, TypeMapping, allocator, from);
}

/// Convert a `testvecor.<any>` to a `codec.<any>`.
pub fn convert(comptime From: type, comptime To: type, allocator: Allocator, from: From) !To {
    return try generic.convert(To, TypeMapping, allocator, from);
}

// Utilities
fn convertHexBytesFixedToArray(comptime size: u32, from: tv_types.hex.HexBytesFixed(size)) [size]u8 {
    var to: [size]u8 = undefined;
    for (from.bytes, 0..) |from_byte, i| {
        to[i] = from_byte;
    }
    return to;
}

fn convertTicketBody(from: tv_lib_codec.TicketBody) lib_codec.TicketBody {
    return lib_codec.TicketBody{
        .id = convertHexBytesFixedToArray(32, from.id),
        .attempt = from.attempt,
    };
}

fn convertAvailAssurance(allocator: Allocator, from: tv_lib_codec.AvailAssurance) !lib_codec.AvailAssurance {
    // anchor: OpaqueHash,
    // bitfield: []u8, // SIZE(avail_bitfield_bytes)
    // validator_index: ValidatorIndex,
    // signature: Ed25519Signature,
    return lib_codec.AvailAssurance{
        .anchor = from.anchor.bytes,
        .bitfield = try allocator.dupe(u8, from.bitfield.bytes),
        .validator_index = from.validator_index,
        .signature = from.signature.bytes,
    };
}

fn convertValidatorSignature(from: tv_lib_codec.ValidatorSignature) lib_codec.ValidatorSignature {
    return lib_codec.ValidatorSignature{
        .validator_index = from.validator_index,
        .signature = from.signature.bytes,
    };
}

fn convertReportGuarantee(allocator: Allocator, from: tv_lib_codec.ReportGuarantee) !lib_codec.ReportGuarantee {
    // report: WorkReport,
    // slot: TimeSlot,
    // signatures: []ValidatorSignature,
    const signatures = try allocator.alloc(lib_codec.ValidatorSignature, from.signatures.len);
    for (from.signatures, signatures) |f, *s| {
        s.* = convertValidatorSignature(f);
    }

    return .{
        .report = try convert(
            tv_lib_codec.WorkReport,
            lib_codec.WorkReport,
            allocator,
            from.report,
        ),
        .slot = from.slot,
        .signatures = signatures,
    };
}

fn convertPreimage(allocator: Allocator, from: tv_lib_codec.Preimage) !lib_codec.Preimage {
    return lib_codec.Preimage{
        .requester = from.requester,
        .blob = try allocator.dupe(u8, from.blob.bytes),
    };
}

fn convertTicketEnvelope(from: tv_lib_codec.TicketEnvelope) lib_codec.TicketEnvelope {
    return lib_codec.TicketEnvelope{
        .attempt = from.attempt,
        .signature = from.signature.bytes,
    };
}

fn convertWorkItem(allocator: Allocator, from: tv_lib_codec.WorkItem) !lib_codec.WorkItem {
    return lib_codec.WorkItem{
        .service = from.service,
        .code_hash = from.code_hash.bytes,
        .payload = try allocator.dupe(u8, from.payload.bytes),
        .refine_gas_limit = from.gas_limit,
        .import_segments = try allocator.dupe(lib_codec.ImportSpec, from.import_segments),
        .extrinsic = try allocator.dupe(lib_codec.ExtrinsicSpec, from.extrinsic),
        .export_count = from.export_count,
    };
}

fn convertWorkReport(allocator: Allocator, from: tv_lib_codec.WorkReport) !lib_codec.WorkReport {
    return lib_codec.WorkReport{
        .package_spec = try convert(tv_lib_codec.WorkPackageSpec, lib_codec.WorkPackageSpec, allocator, from.package_spec),
        .context = try convert(
            tv_lib_codec.RefineContext,
            lib_codec.RefineContext,
            allocator,
            from.context,
        ),
        .core_index = from.core_index,
        .authorizer_hash = from.authorizer_hash.bytes,
        .auth_output = try allocator.dupe(u8, from.auth_output.bytes),
        .segment_root_lookup = try convert(tv_lib_codec.SegmentRootLookup, lib_codec.SegmentRootLookup, allocator, from.segment_root_lookup),
        .results = try convert([]tv_lib_codec.WorkResult, []lib_codec.WorkResult, allocator, from.results),
        .stats = .{
            .auth_gas_used = from.auth_gas_used,
        },
    };
}
