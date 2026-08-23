const std = @import("std");
const msg = @import("message.zig");
const Layer = msg.Layer;
const Widget = msg.Widget;
const BorderType = msg.BorderType;
const blend_mod = @import("blend.zig");
const scene_mod = @import("scene.zig");
const Rect = scene_mod.Rect;

pub const FONT_WIDTH: u32 = 8;
pub const FONT_HEIGHT: u32 = 16;

pub fn parseHexRgb(str: []const u8) u32 {
    var s = str;
    if (std.mem.startsWith(u8, s, "#")) {
        s = s[1..];
    }
    if (s.len == 6) {
        const r = std.fmt.parseInt(u32, s[0..2], 16) catch 255;
        const g = std.fmt.parseInt(u32, s[2..4], 16) catch 255;
        const b = std.fmt.parseInt(u32, s[4..6], 16) catch 255;
        return 0xff000000 | (r << 16) | (g << 8) | b;
    }
    if (std.mem.eql(u8, str, "red")) return 0xfff38ba8;
    if (std.mem.eql(u8, str, "green")) return 0xffa6e3a1;
    if (std.mem.eql(u8, str, "yellow")) return 0xfff9e2af;
    if (std.mem.eql(u8, str, "blue")) return 0xff89b4fa;
    if (std.mem.eql(u8, str, "cyan")) return 0xff89dceb;
    if (std.mem.eql(u8, str, "magenta") or std.mem.eql(u8, str, "pink")) return 0xfff5c2e7;
    if (std.mem.eql(u8, str, "white")) return 0xffcdd6f4;
    if (std.mem.eql(u8, str, "black")) return 0xff11111b;

    return 0xffcdd6f4; // Catppuccin Text default
}

pub fn fillPixelRect(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    rx: i32,
    ry: i32,
    rw: u32,
    rh: u32,
    color: u32,
) void {
    const x_start = @max(0, rx);
    const y_start = @max(0, ry);
    const x_end = @min(@as(i32, @intCast(width)), rx + @as(i32, @intCast(rw)));
    const y_end = @min(@as(i32, @intCast(height)), ry + @as(i32, @intCast(rh)));

    if (x_end <= x_start or y_end <= y_start) return;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        const row_offset = @as(usize, @intCast(y)) * @as(usize, stride);
        var x = x_start;
        while (x < x_end) : (x += 1) {
            pixels[row_offset + @as(usize, @intCast(x))] = color;
        }
    }
}

pub fn drawChar(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    cp: u21,
    px: i32,
    py: i32,
    fg_col: u32,
) void {
    var row: u16 = 0;
    while (row < FONT_HEIGHT) : (row += 1) {
        const target_y = py + @as(i32, @intCast(row));
        if (target_y < 0 or target_y >= height) continue;

        const bits = getGlyphRowBits(cp, row);
        var col: u16 = 0;
        while (col < FONT_WIDTH) : (col += 1) {
            const target_x = px + @as(i32, @intCast(col));
            if (target_x < 0 or target_x >= width) continue;

            const bit_set = ((bits >> @intCast(7 - col)) & 1) != 0;
            if (bit_set) {
                const idx = @as(usize, @intCast(target_y)) * @as(usize, stride) + @as(usize, @intCast(target_x));
                pixels[idx] = fg_col;
            }
        }
    }
}

pub fn drawText(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    text: []const u8,
    px: i32,
    py: i32,
    fg_col: u32,
) void {
    var cur_x = px;
    if (std.unicode.Utf8View.init(text)) |view| {
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            drawChar(pixels, stride, width, height, cp, cur_x, py, fg_col);
            cur_x += @as(i32, @intCast(FONT_WIDTH));
        }
    } else |_| {
        for (text) |byte| {
            drawChar(pixels, stride, width, height, byte, cur_x, py, fg_col);
            cur_x += @as(i32, @intCast(FONT_WIDTH));
        }
    }
}

pub fn drawBoxBorders(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    rect: Rect,
    border: BorderType,
    border_color: u32,
    title: ?[]const u8,
) void {
    if (border == .none or rect.width < 16 or rect.height < 16) return;

    const rx = rect.x;
    const ry = rect.y;
    const rw = rect.width;
    const rh = rect.height;

    // Top border line
    fillPixelRect(pixels, stride, width, height, rx + 4, ry, rw - 8, 2, border_color);
    // Bottom border line
    fillPixelRect(pixels, stride, width, height, rx + 4, ry + @as(i32, @intCast(rh)) - 2, rw - 8, 2, border_color);
    // Left border line
    fillPixelRect(pixels, stride, width, height, rx, ry + 4, 2, rh - 8, border_color);
    // Right border line
    fillPixelRect(pixels, stride, width, height, rx + @as(i32, @intCast(rw)) - 2, ry + 4, 2, rh - 8, border_color);

    // Title if present
    if (title) |t| {
        const title_w = @as(u32, @intCast(t.len)) * FONT_WIDTH;
        if (title_w + 24 < rw) {
            const tx = rx + 16;
            // Erase behind title
            fillPixelRect(pixels, stride, width, height, tx - 4, ry - 4, title_w + 8, FONT_HEIGHT, 0xff1e1e2e);
            drawText(pixels, stride, width, height, t, tx, ry - 2, border_color);
        }
    }
}

pub fn renderLayer(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    layer: Layer,
    rect: Rect,
) void {
    if (!layer.visible) return;

    // 1. Drop shadow
    if (layer.style.shadow) {
        blend_mod.drawDropShadow(pixels, stride, width, height, rect.x, rect.y, rect.width, rect.height, 8);
    }

    // 2. Layer background
    const bg_col = if (layer.style.bg) |bg| parseHexRgb(bg) else 0xff1e1e2e;
    fillPixelRect(pixels, stride, width, height, rect.x, rect.y, rect.width, rect.height, bg_col);

    // 3. Borders & Title
    const border_col = if (layer.style.border_fg) |bfg| parseHexRgb(bfg) else 0xff89b4fa;
    drawBoxBorders(pixels, stride, width, height, rect, layer.style.border, border_col, layer.style.title);

    // 4. Render children widgets
    var cur_y: i32 = rect.y + 12;
    for (layer.children) |w| {
        cur_y += @as(i32, @intCast(w.margin_top)) * @as(i32, @intCast(FONT_HEIGHT));
        renderWidget(pixels, stride, width, height, w, rect.x + 12, cur_y, rect.width - 24);
        cur_y += @as(i32, @intCast(FONT_HEIGHT)) + 4 + @as(i32, @intCast(w.gap));
    }
}

fn renderWidget(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    w: Widget,
    wx: i32,
    wy: i32,
    avail_w: u32,
) void {
    switch (w.type) {
        .text => {
            if (w.text) |t| {
                const fg = if (w.style.fg) |fg_str| parseHexRgb(fg_str) else 0xffcdd6f4;
                var tx = wx;
                if (w.@"align" == .center) {
                    const txt_len_px = @as(u32, @intCast(t.len)) * FONT_WIDTH;
                    if (txt_len_px < avail_w) {
                        tx = wx + @as(i32, @intCast((avail_w - txt_len_px) / 2));
                    }
                }
                drawText(pixels, stride, width, height, t, tx, wy, fg);
            }
        },
        .header => {
            if (w.title) |t| {
                fillPixelRect(pixels, stride, width, height, wx - 4, wy - 2, avail_w + 8, FONT_HEIGHT + 4, 0xff89b4fa);
                drawText(pixels, stride, width, height, t, wx + 4, wy, 0xff11111b);
            }
        },
        .button => {
            if (w.label) |lbl| {
                const is_danger = if (w.variant) |v| std.mem.eql(u8, v, "danger") else false;
                const btn_bg: u32 = if (w.focused) (if (is_danger) @as(u32, 0xfff38ba8) else @as(u32, 0xff89b4fa)) else @as(u32, 0xff313244);
                const btn_fg: u32 = if (w.focused) 0xff11111b else 0xffcdd6f4;
                const btn_w = @as(u32, @intCast(lbl.len + 4)) * FONT_WIDTH;

                fillPixelRect(pixels, stride, width, height, wx, wy - 2, btn_w, FONT_HEIGHT + 4, btn_bg);
                drawText(pixels, stride, width, height, lbl, wx + 8, wy, btn_fg);
            }
        },
        .box => {
            var child_x = wx;
            for (w.children) |child| {
                renderWidget(pixels, stride, width, height, child, child_x, wy, avail_w);
                child_x += 120 + @as(i32, @intCast(w.gap * FONT_WIDTH));
            }
        },
        .table => {
            var row_y = wy;
            // Draw headers
            var h_x = wx;
            for (w.headers) |h| {
                drawText(pixels, stride, width, height, h, h_x, row_y, 0xffa6adc8);
                h_x += 100;
            }
            row_y += FONT_HEIGHT + 2;

            // Draw rows
            for (w.rows, 0..) |row, r_idx| {
                var c_x = wx;
                const is_selected = (w.selected_index != null and w.selected_index.? == r_idx);
                if (is_selected) {
                    fillPixelRect(pixels, stride, width, height, wx - 4, row_y - 2, avail_w + 8, FONT_HEIGHT + 2, 0xff45475a);
                }
                const cell_fg: u32 = if (is_selected) 0xff89dceb else 0xffcdd6f4;
                for (row) |cell_txt| {
                    drawText(pixels, stride, width, height, cell_txt, c_x, row_y, cell_fg);
                    c_x += 100;
                }
                row_y += FONT_HEIGHT + 2;
            }
        },
        .list => {
            var item_y = wy;
            for (w.items, 0..) |item, i_idx| {
                const is_selected = (w.selected_index != null and w.selected_index.? == i_idx);
                if (is_selected) {
                    fillPixelRect(pixels, stride, width, height, wx - 4, item_y - 2, avail_w + 8, FONT_HEIGHT + 2, 0xff45475a);
                }
                const item_fg: u32 = if (is_selected) 0xff89dceb else 0xffcdd6f4;
                drawText(pixels, stride, width, height, item, wx, item_y, item_fg);
                item_y += FONT_HEIGHT + 2;
            }
        },
        else => {},
    }
}

fn getGlyphRowBits(cp: u21, row: u16) u8 {
    if (row >= FONT_HEIGHT) return 0;

    return switch (cp) {
        ' ' => 0,
        '!' => if (row >= 3 and row <= 10) 0b00011000 else if (row == 13) 0b00011000 else 0,
        '"' => if (row >= 3 and row <= 6) 0b00100100 else 0,
        '#' => if (row == 6 or row == 10) 0b01111110 else if (row >= 4 and row <= 12) 0b00100100 else 0,
        '$' => if (row == 3 or row == 7 or row == 12) 0b00111100 else if (row >= 2 and row <= 13) 0b00011000 else 0,
        '%' => if (row == 4 or row == 11) 0b01100010 else if (row == 5 or row == 10) 0b01100100 else if (row >= 6 and row <= 9) 0b00001000 else 0,
        '&' => if (row == 4) 0b00110000 else if (row == 7) 0b00110000 else if (row == 11) 0b01101110 else if (row >= 5 and row <= 10) 0b01001000 else 0,
        '\'' => if (row >= 3 and row <= 5) 0b00011000 else 0,
        '(' => if (row == 3 or row == 13) 0b00001100 else if (row >= 4 and row <= 12) 0b00011000 else 0,
        ')' => if (row == 3 or row == 13) 0b00110000 else if (row >= 4 and row <= 12) 0b00011000 else 0,
        '*' => if (row == 6 or row == 8) 0b00101000 else if (row == 7) 0b01111100 else 0,
        '+' => if (row == 8) 0b01111110 else if (row >= 5 and row <= 11) 0b00011000 else 0,
        ',' => if (row == 12) 0b00011000 else if (row == 13) 0b00010000 else if (row == 14) 0b00100000 else 0,
        '-' => if (row == 8) 0b01111110 else 0,
        '.' => if (row == 12 or row == 13) 0b00011000 else 0,
        '/' => if (row >= 3 and row <= 13) (@as(u8, 1) << @intCast(13 - row)) else 0,
        '0' => if (row == 4 or row == 12) 0b00111100 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        '1' => if (row == 4) 0b00011000 else if (row == 5) 0b00111000 else if (row >= 6 and row <= 12) 0b00011000 else if (row == 13) 0b01111110 else 0,
        '2' => if (row == 4) 0b00111100 else if (row == 5 or row == 6) 0b01100110 else if (row == 7) 0b00000110 else if (row == 8) 0b00001100 else if (row == 9) 0b00011000 else if (row == 10) 0b00110000 else if (row == 11) 0b01100000 else if (row == 12 or row == 13) 0b01111110 else 0,
        '3' => if (row == 4 or row == 12) 0b00111100 else if (row == 8) 0b00011100 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        '4' => if (row == 10) 0b01111110 else if (row >= 4 and row <= 9) 0b01100110 else if (row >= 11 and row <= 13) 0b00000110 else 0,
        '5' => if (row == 4 or row == 8 or row == 12) 0b01111110 else if (row >= 5 and row <= 7) 0b01100000 else if (row >= 9 and row <= 11) 0b00000110 else 0,
        '6' => if (row == 4 or row == 8 or row == 12) 0b00111100 else if (row >= 5 and row <= 7) 0b01100000 else if (row >= 9 and row <= 11) 0b01100110 else 0,
        '7' => if (row == 4) 0b01111110 else if (row == 5 or row == 6) 0b00000110 else if (row == 7 or row == 8) 0b00001100 else if (row >= 9 and row <= 13) 0b00011000 else 0,
        '8' => if (row == 4 or row == 8 or row == 12) 0b00111100 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        '9' => if (row == 4 or row == 8 or row == 12) 0b00111100 else if (row >= 5 and row <= 7) 0b01100110 else if (row >= 9 and row <= 11) 0b00000110 else 0,
        ':' => if (row == 7 or row == 8 or row == 11 or row == 12) 0b00011000 else 0,
        ';' => if (row == 7 or row == 8) 0b00011000 else if (row == 11 or row == 12) 0b00011000 else if (row == 13) 0b00010000 else if (row == 14) 0b00100000 else 0,
        '<' => if (row == 5 or row == 11) 0b00001100 else if (row == 6 or row == 10) 0b00011000 else if (row == 7 or row == 9) 0b00110000 else if (row == 8) 0b01100000 else 0,
        '=' => if (row == 7 or row == 9) 0b01111110 else 0,
        '>' => if (row == 5 or row == 11) 0b00110000 else if (row == 6 or row == 10) 0b00011000 else if (row == 7 or row == 9) 0b00001100 else if (row == 8) 0b00000110 else 0,
        '?' => if (row == 4) 0b00111100 else if (row == 5) 0b01100110 else if (row == 6) 0b00000110 else if (row == 7) 0b00001100 else if (row == 8) 0b00011000 else if (row == 9) 0b00011000 else if (row == 12 or row == 13) 0b00011000 else 0,
        '@' => if (row == 4 or row == 12) 0b00111100 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        'A' => if (row == 4) 0b00011000 else if (row == 5) 0b00111100 else if (row == 8) 0b01111110 else if (row >= 6 and row <= 13) 0b01100110 else 0,
        'B' => if (row == 4 or row == 8 or row == 12) 0b01111100 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        'C' => if (row == 4 or row == 12) 0b00111100 else if (row >= 5 and row <= 11) 0b01100000 else 0,
        'D' => if (row == 4 or row == 12) 0b01111000 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        'E' => if (row == 4 or row == 8 or row == 12) 0b01111110 else if (row >= 5 and row <= 11) 0b01100000 else 0,
        'F' => if (row == 4 or row == 8) 0b01111110 else if (row >= 5 and row <= 13) 0b01100000 else 0,
        'G' => if (row == 4 or row == 12) 0b00111100 else if (row == 8) 0b01101110 else if (row >= 9 and row <= 11) 0b01100110 else if (row >= 5 and row <= 7) 0b01100000 else 0,
        'H' => if (row == 8) 0b01111110 else if (row >= 4 and row <= 13) 0b01100110 else 0,
        'I' => if (row == 4 or row == 13) 0b01111110 else if (row >= 5 and row <= 12) 0b00011000 else 0,
        'J' => if (row == 4) 0b00001110 else if (row >= 5 and row <= 11) 0b00000110 else if (row == 12) 0b01100110 else if (row == 13) 0b00111100 else 0,
        'K' => if (row == 8) 0b01111000 else if (row >= 4 and row <= 13) 0b01100110 else 0,
        'L' => if (row == 12 or row == 13) 0b01111110 else if (row >= 4 and row <= 11) 0b01100000 else 0,
        'M' => if (row == 4 or row == 5) 0b01100110 else if (row == 6 or row == 7) 0b01111110 else if (row >= 8 and row <= 13) 0b01100110 else 0,
        'N' => if (row >= 4 and row <= 13) 0b01100110 else 0,
        'O' => if (row == 4 or row == 12) 0b00111100 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        'P' => if (row == 4 or row == 8) 0b01111100 else if (row >= 5 and row <= 7) 0b01100110 else if (row >= 9 and row <= 13) 0b01100000 else 0,
        'Q' => if (row == 4 or row == 12) 0b00111100 else if (row == 13) 0b00001110 else if (row >= 5 and row <= 11) 0b01100110 else 0,
        'R' => if (row == 4 or row == 8) 0b01111100 else if (row >= 5 and row <= 7) 0b01100110 else if (row >= 9 and row <= 13) 0b01100110 else 0,
        'S' => if (row == 4 or row == 8 or row == 12) 0b00111100 else if (row >= 5 and row <= 7) 0b01100000 else if (row >= 9 and row <= 11) 0b00000110 else 0,
        'T' => if (row == 4) 0b01111110 else if (row >= 5 and row <= 13) 0b00011000 else 0,
        'U' => if (row == 12 or row == 13) 0b00111100 else if (row >= 4 and row <= 11) 0b01100110 else 0,
        'V' => if (row >= 4 and row <= 10) 0b01100110 else if (row == 11 or row == 12) 0b00111100 else if (row == 13) 0b00011000 else 0,
        'W' => if (row >= 4 and row <= 9) 0b01100110 else if (row == 10 or row == 11) 0b01111110 else if (row >= 12 and row <= 13) 0b01100110 else 0,
        'X' => if (row == 8) 0b00111100 else if (row >= 4 and row <= 13) 0b01100110 else 0,
        'Y' => if (row >= 4 and row <= 7) 0b01100110 else if (row == 8) 0b00111100 else if (row >= 9 and row <= 13) 0b00011000 else 0,
        'Z' => if (row == 4 or row == 12 or row == 13) 0b01111110 else if (row == 5 or row == 6) 0b00001100 else if (row == 7 or row == 8) 0b00011000 else if (row >= 9 and row <= 11) 0b00110000 else 0,
        '[' => if (row == 3 or row == 13) 0b00111100 else if (row >= 4 and row <= 12) 0b00110000 else 0,
        '\\' => if (row >= 3 and row <= 13) (@as(u8, 1) << @intCast(row - 3)) else 0,
        ']' => if (row == 3 or row == 13) 0b00111100 else if (row >= 4 and row <= 12) 0b00001100 else 0,
        '^' => if (row == 4) 0b00011000 else if (row == 5) 0b00111100 else if (row == 6) 0b01100110 else 0,
        '_' => if (row == 14) 0b11111111 else 0,
        '`' => if (row == 3) 0b00100000 else if (row == 4) 0b00010000 else 0,
        'a' => if (row == 7 or row == 10 or row == 13) 0b00111100 else if (row >= 8 and row <= 12) 0b01100110 else 0,
        'b' => if (row >= 4 and row <= 13) (if (row == 7 or row == 13) @as(u8, 0b01111100) else 0b01100110) else 0,
        'c' => if (row == 7 or row == 13) 0b00111100 else if (row >= 8 and row <= 12) 0b01100000 else 0,
        'd' => if (row >= 4 and row <= 13) (if (row == 7 or row == 13) @as(u8, 0b00111110) else 0b01100110) else 0,
        'e' => if (row == 7 or row == 10 or row == 13) 0b00111100 else if (row == 8 or row == 9) 0b01100110 else if (row >= 11 and row <= 12) 0b01100000 else 0,
        'f' => if (row == 4 or row == 7) 0b00111100 else if (row >= 5 and row <= 13) 0b00011000 else 0,
        'g' => if (row == 7 or row == 11 or row == 14) 0b00111100 else if (row >= 8 and row <= 10) 0b01100110 else if (row >= 12 and row <= 13) 0b00000110 else 0,
        'h' => if (row == 8) 0b01111100 else if (row >= 4 and row <= 13) (if (row < 8) @as(u8, 0b01100000) else 0b01100110) else 0,
        'i' => if (row == 4 or row == 5) 0b00011000 else if (row >= 7 and row <= 13) 0b00011000 else 0,
        'j' => if (row == 4 or row == 5) 0b00001100 else if (row >= 7 and row <= 13) 0b00001100 else if (row == 14) 0b00111000 else 0,
        'k' => if (row == 9) 0b01111000 else if (row >= 4 and row <= 13) (if (row < 7) @as(u8, 0b01100000) else 0b01100110) else 0,
        'l' => if (row >= 4 and row <= 12) 0b00011000 else if (row == 13) 0b00011100 else 0,
        'm' => if (row == 7) 0b01110110 else if (row >= 8 and row <= 13) 0b01101011 else 0,
        'n' => if (row == 7) 0b01111100 else if (row >= 8 and row <= 13) 0b01100110 else 0,
        'o' => if (row == 7 or row == 13) 0b00111100 else if (row >= 8 and row <= 12) 0b01100110 else 0,
        'p' => if (row == 7 or row == 11) 0b01111100 else if (row >= 8 and row <= 10) 0b01100110 else if (row >= 12 and row <= 15) 0b01100000 else 0,
        'q' => if (row == 7 or row == 11) 0b00111110 else if (row >= 8 and row <= 10) 0b01100110 else if (row >= 12 and row <= 15) 0b00000110 else 0,
        'r' => if (row == 7) 0b01101100 else if (row == 8) 0b01110000 else if (row >= 9 and row <= 13) 0b01100000 else 0,
        's' => if (row == 7 or row == 10 or row == 13) 0b00111100 else if (row >= 8 and row <= 9) 0b01100000 else if (row >= 11 and row <= 12) 0b00000110 else 0,
        't' => if (row == 5 or row == 7) 0b01111110 else if (row >= 6 and row <= 12) 0b00011000 else if (row == 13) 0b00011100 else 0,
        'u' => if (row == 13) 0b00111110 else if (row >= 7 and row <= 12) 0b01100110 else 0,
        'v' => if (row >= 7 and row <= 11) 0b01100110 else if (row == 12) 0b00111100 else if (row == 13) 0b00011000 else 0,
        'w' => if (row >= 7 and row <= 11) 0b01100110 else if (row == 12) 0b01111110 else if (row == 13) 0b01100110 else 0,
        'x' => if (row == 10) 0b00111100 else if (row >= 7 and row <= 13) 0b01100110 else 0,
        'y' => if (row >= 7 and row <= 11) 0b01100110 else if (row == 12) 0b00111110 else if (row >= 13 and row <= 14) 0b00000110 else if (row == 15) 0b00111100 else 0,
        'z' => if (row == 7 or row == 13) 0b01111110 else if (row == 8 or row == 9) 0b00001100 else if (row == 10) 0b00011000 else if (row >= 11 and row <= 12) 0b00110000 else 0,
        '{' => if (row == 3 or row == 13) 0b00001100 else if (row == 8) 0b00011000 else if (row >= 4 and row <= 12) 0b00010000 else 0,
        '|' => 0b00011000,
        '}' => if (row == 3 or row == 13) 0b00110000 else if (row == 8) 0b00011000 else if (row >= 4 and row <= 12) 0b00001000 else 0,
        '~' => if (row == 6) 0b00110110 else if (row == 7) 0b01101100 else 0,
        0x25B6 => switch (row) {
            4, 12 => 0b00100000,
            5, 11 => 0b00110000,
            6, 10 => 0b00111000,
            7, 9 => 0b00111100,
            8 => 0b00111110,
            else => 0,
        },
        0x25C0 => switch (row) {
            4, 12 => 0b00000100,
            5, 11 => 0b00001100,
            6, 10 => 0b00011000,
            7, 9 => 0b00111100,
            8 => 0b01111100,
            else => 0,
        },
        else => 0,
    };
}
