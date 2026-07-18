const impl = @import("x86_64/kvm_boot.zig");

pub fn main(init: @import("std").process.Init) !void {
    return impl.main(init);
}
