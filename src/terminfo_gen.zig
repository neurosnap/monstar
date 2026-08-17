const std = @import("std");
const terminfo = @import("ghostty-terminfo");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    defer writer.interface.flush() catch {};
    try terminfo.ghostty.encode(&writer.interface);
}
