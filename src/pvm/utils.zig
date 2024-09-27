pub fn updatePc(pc: u32, offset: i32) !u32 {
    if (offset >= 0) {
        return pc +% @as(u32, @intCast(offset));
    } else {
        const abs_offset = @abs(offset);
        if (abs_offset > pc) {
            return error.PcUnderflow;
        }
        return pc - abs_offset;
    }
}
