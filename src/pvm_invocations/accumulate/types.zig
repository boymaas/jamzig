const std = @import("std");

const types = @import("../../types.zig");

const Params = @import("../../jam_params.zig").Params;

/// DeferredTransfer is an alias for TransferOperand (v0.7.1 uses inline processing)
/// Kept for compatibility during transition - will be removed in final cleanup
pub const DeferredTransfer = @import("../accumulate.zig").TransferOperand;
