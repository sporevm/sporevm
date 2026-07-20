const impl = @import("x86_64/profile_roundtrip.zig");

pub fn main(init: @import("std").process.Init) !void {
    return impl.main(init);
}
