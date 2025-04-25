/// Callback type for command completion
pub fn CommandCallback(T: type) type {
    return *const fn (result: T, context: ?*anyopaque) void;
}

pub fn CommandMetadata(T: type) type {
    return struct {
        callback: ?CommandCallback(T) = null,
        context: ?*anyopaque = null,

        pub fn callWithResult(self: *const CommandMetadata(T), result: T) void {
            if (self.callback) |callback| {
                callback(result, self.context);
            }
        }
    };
}
