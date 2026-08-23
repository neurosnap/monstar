const std = @import("std");

pub fn dimPixels(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    factor: f32,
) void {
    const scale: u32 = @intFromFloat(std.math.clamp(1.0 - factor, 0.0, 1.0) * 255.0);
    if (scale >= 255) return;

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_start = y * @as(usize, stride);
        const row_end = row_start + width;
        for (pixels[row_start..row_end]) |*px| {
            const orig = px.*;
            const a = orig & 0xff000000;
            const r = (((orig >> 16) & 0xff) * scale) / 255;
            const g = (((orig >> 8) & 0xff) * scale) / 255;
            const b = ((orig & 0xff) * scale) / 255;
            px.* = a | (r << 16) | (g << 8) | b;
        }
    }
}

pub fn drawDropShadow(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    rx: i32,
    ry: i32,
    rw: u32,
    rh: u32,
    shadow_size: u32,
) void {
    if (rw == 0 or rh == 0) return;

    const s_offset_x: i32 = @intCast(shadow_size);
    const s_offset_y: i32 = @intCast(shadow_size);

    const x_start = rx + s_offset_x;
    const y_start = ry + s_offset_y;
    const x_end = rx + @as(i32, @intCast(rw)) + s_offset_x;
    const y_end = ry + @as(i32, @intCast(rh)) + s_offset_y;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        if (y < 0 or y >= height) continue;
        var x = x_start;
        while (x < x_end) : (x += 1) {
            if (x < 0 or x >= width) continue;

            // Only shade area outside original rect
            if (x >= rx and x < rx + @as(i32, @intCast(rw)) and y >= ry and y < ry + @as(i32, @intCast(rh))) {
                continue;
            }

            const idx = @as(usize, @intCast(y)) * @as(usize, stride) + @as(usize, @intCast(x));
            const orig = pixels[idx];
            const a = orig & 0xff000000;
            const r = (((orig >> 16) & 0xff) * 4) / 10;
            const g = (((orig >> 8) & 0xff) * 4) / 10;
            const b = ((orig & 0xff) * 4) / 10;
            pixels[idx] = a | (r << 16) | (g << 8) | b;
        }
    }
}
