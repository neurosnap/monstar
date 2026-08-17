const std = @import("std");
const terminfo = @import("ghostty-terminfo");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    defer writer.interface.flush() catch {};

    try write(&writer.interface);
}

fn write(writer: *std.Io.Writer) !void {
    var monstar = terminfo.ghostty;
    monstar.names = &.{ "monstar", "Monstar terminal" };
    try monstar.encode(writer);
}

test "checked-in terminfo source is current" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try write(&writer.writer);
    try std.testing.expectEqualStrings(@embedFile("monstar-terminfo-source"), writer.written());
}
