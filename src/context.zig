const std = @import("std");

pub const Context = struct {
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
};
