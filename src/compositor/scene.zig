const std = @import("std");
const vt = @import("ghostty-vt");
const msg = @import("message.zig");
const Layer = msg.Layer;
const Widget = msg.Widget;
const Anchor = msg.Anchor;

pub const EventAction = union(enum) {
    none,
    redraw,
    dismiss: []const u8,
    click: struct { layer_id: []const u8, widget_id: []const u8 },
    submit: struct { layer_id: []const u8, widget_id: ?[]const u8, value: ?[]const u8, selected_index: ?usize },
    change: struct { layer_id: []const u8, widget_id: []const u8, value: []const u8 },
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < (self.x + @as(i32, @intCast(self.width))) and
            py >= self.y and py < (self.y + @as(i32, @intCast(self.height)));
    }
};

pub const HitResult = struct {
    layer_id: []const u8,
    widget_id: ?[]const u8 = null,
    local_x: i32,
    local_y: i32,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    layers: std.ArrayList(Layer),
    active_focus_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .layers = .empty,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.arena.deinit();
        self.layers.deinit(self.allocator);
    }

    pub fn clear(self: *Scene) void {
        self.layers.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.active_focus_id = null;
    }

    pub fn setLayers(self: *Scene, new_layers: []const Layer) !void {
        self.layers.clearRetainingCapacity();
        try self.layers.appendSlice(self.allocator, new_layers);

        // Auto-find focused widget ID if present
        for (self.layers.items) |layer| {
            if (layer.visible) {
                if (findFocusedWidget(layer.children)) |f_id| {
                    self.active_focus_id = f_id;
                }
            }
        }
    }

    pub fn removeLayer(self: *Scene, id: []const u8) void {
        var i: usize = 0;
        while (i < self.layers.items.len) {
            if (std.mem.eql(u8, self.layers.items[i].id, id)) {
                _ = self.layers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn hasActiveModal(self: *const Scene) bool {
        for (self.layers.items) |l| {
            if (l.visible and (l.type == .modal or l.style.backdrop != null)) return true;
        }
        return false;
    }

    pub fn getTopmostFocusedLayer(self: *const Scene) ?*const Layer {
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            const l = &self.layers.items[i];
            if (l.visible) return l;
        }
        return null;
    }

    pub fn handleKeyEvent(self: *Scene, key: vt.input.Key, utf8: []const u8, mods: vt.input.KeyMods) EventAction {
        if (self.layers.items.len == 0) return .none;

        var top_layer: ?*Layer = null;
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            if (self.layers.items[i].visible) {
                top_layer = &self.layers.items[i];
                break;
            }
        }
        const layer = top_layer orelse return .none;

        // 1. Escape: dismiss active layer
        if (key == .escape) {
            const lid = layer.id;
            self.layers.clearRetainingCapacity();
            self.active_focus_id = null;
            return .{ .dismiss = lid };
        }

        // 2. Tab: cycle focus
        if (key == .tab) {
            cycleFocus(layer.children, mods.shift);
            return .redraw;
        }

        // 3. Up / Down arrows: navigate list or table
        if (key == .arrow_up or key == .arrow_down) {
            if (findFirstListOrTable(layer.children)) |list_w| {
                if (list_w.items.len > 0) {
                    var cur = list_w.selected_index orelse 0;
                    if (key == .arrow_down) {
                        if (cur + 1 < list_w.items.len) cur += 1;
                    } else {
                        if (cur > 0) cur -= 1;
                    }
                    list_w.selected_index = cur;
                    return .redraw;
                }
            }
        }

        // 4. Enter: trigger focused button or submit list / input
        if (key == .enter or key == .numpad_enter) {
            if (findFocusedWidgetPtr(layer.children)) |fw| {
                if (fw.type == .button) {
                    return .{ .click = .{
                        .layer_id = layer.id,
                        .widget_id = fw.id orelse "button",
                    } };
                }
            }

            if (findFirstListOrTable(layer.children)) |list_w| {
                const sel = list_w.selected_index orelse 0;
                const sel_val = if (sel < list_w.items.len) list_w.items[sel] else null;
                return .{ .submit = .{
                    .layer_id = layer.id,
                    .widget_id = list_w.id,
                    .value = sel_val,
                    .selected_index = sel,
                } };
            }

            if (findFocusedInput(layer.children)) |inp| {
                return .{ .submit = .{
                    .layer_id = layer.id,
                    .widget_id = inp.id,
                    .value = inp.value,
                    .selected_index = null,
                } };
            }

            return .none;
        }

        // 5. Input text editing on focused input widget
        if (findFocusedInput(layer.children)) |inp| {
            if (key == .backspace or key == .numpad_backspace) {
                if (inp.value) |v| {
                    if (v.len > 0 and inp.cursor_pos > 0) {
                        const pos = @min(v.len, @as(usize, inp.cursor_pos));
                        var new_buf = self.arena.allocator().alloc(u8, v.len - 1) catch return .none;
                        @memcpy(new_buf[0 .. pos - 1], v[0 .. pos - 1]);
                        @memcpy(new_buf[pos - 1 ..], v[pos..]);
                        inp.value = new_buf;
                        inp.cursor_pos -= 1;
                        return .{ .change = .{
                            .layer_id = layer.id,
                            .widget_id = inp.id orelse "input",
                            .value = new_buf,
                        } };
                    }
                }
                return .redraw;
            }

            if (key == .arrow_left) {
                if (inp.cursor_pos > 0) inp.cursor_pos -= 1;
                return .redraw;
            }

            if (key == .arrow_right) {
                if (inp.value) |v| {
                    if (inp.cursor_pos < v.len) inp.cursor_pos += 1;
                }
                return .redraw;
            }

            if (key == .home) {
                inp.cursor_pos = 0;
                return .redraw;
            }

            if (key == .end) {
                if (inp.value) |v| inp.cursor_pos = @intCast(v.len);
                return .redraw;
            }

            // Printable text input
            if (utf8.len > 0 and utf8[0] >= 32 and !mods.ctrl and !mods.alt) {
                const old_val = inp.value orelse "";
                const pos = @min(old_val.len, @as(usize, inp.cursor_pos));
                var new_buf = self.arena.allocator().alloc(u8, old_val.len + utf8.len) catch return .none;
                @memcpy(new_buf[0..pos], old_val[0..pos]);
                @memcpy(new_buf[pos .. pos + utf8.len], utf8);
                @memcpy(new_buf[pos + utf8.len ..], old_val[pos..]);
                inp.value = new_buf;
                inp.cursor_pos += @intCast(utf8.len);
                return .{ .change = .{
                    .layer_id = layer.id,
                    .widget_id = inp.id orelse "input",
                    .value = new_buf,
                } };
            }
        }

        return .none;
    }

    pub fn handlePointerClick(self: *Scene, px: i32, py: i32, screen_w: u32, screen_h: u32, cell_w: u32, cell_h: u32) EventAction {
        if (self.layers.items.len == 0) return .none;

        var top_layer: ?*Layer = null;
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            if (self.layers.items[i].visible) {
                top_layer = &self.layers.items[i];
                break;
            }
        }
        const layer = top_layer orelse return .none;
        const l_rect = computeLayerRect(layer.*, screen_w, screen_h, 0, 0, cell_w, cell_h);

        // Clicked outside modal -> dismiss
        if (!l_rect.contains(px, py)) {
            const lid = layer.id;
            self.layers.clearRetainingCapacity();
            self.active_focus_id = null;
            return .{ .dismiss = lid };
        }

        const lx = px - l_rect.x;
        const ly = py - l_rect.y;

        const has_border_or_title = layer.style.border != .none or layer.style.title != null;
        var cur_y: i32 = @as(i32, @intCast(cell_h)) + (if (has_border_or_title) @as(i32, 8) else @as(i32, 4));

        const rasterizer = @import("rasterizer.zig");

        for (layer.children) |*w| {
            cur_y += @as(i32, @intCast(w.margin_top)) * @as(i32, @intCast(cell_h));
            const w_height = rasterizer.widgetHeight(w.*, cell_h);

            if (ly >= cur_y and ly < cur_y + w_height) {
                switch (w.type) {
                    .list => {
                        if (w.items.len > 0) {
                            const row_h = @as(i32, @intCast(cell_h + 2));
                            const clicked_idx_i = @divFloor(ly - cur_y, row_h);
                            if (clicked_idx_i >= 0 and clicked_idx_i < w.items.len) {
                                const sel: usize = @intCast(clicked_idx_i);
                                w.selected_index = sel;
                                return .{ .submit = .{
                                    .layer_id = layer.id,
                                    .widget_id = w.id,
                                    .value = w.items[sel],
                                    .selected_index = sel,
                                } };
                            }
                        }
                    },
                    .button => {
                        return .{ .click = .{
                            .layer_id = layer.id,
                            .widget_id = w.id orelse "button",
                        } };
                    },
                    .input => {
                        w.focused = true;
                        const char_idx = @divFloor(@max(0, lx - 12), @as(i32, @intCast(cell_w)));
                        const text_len = if (w.value) |v| v.len else 0;
                        w.cursor_pos = @intCast(@min(text_len, @as(usize, @intCast(@max(0, char_idx)))));
                        return .redraw;
                    },
                    else => {},
                }
            }

            cur_y += w_height + @as(i32, @intCast(w.gap));
        }

        return .none;
    }

    pub fn computeLayerRect(layer: Layer, screen_w: u32, screen_h: u32, cursor_x: i32, cursor_y: i32, cell_w: u32, cell_h: u32) Rect {
        const layer_pixel_w: u32 = @as(u32, layer.width) * cell_w;
        const layer_pixel_h: u32 = @as(u32, layer.height) * cell_h;

        var rx: i32 = 0;
        var ry: i32 = 0;

        switch (layer.anchor) {
            .center => {
                rx = @divTrunc(@as(i32, @intCast(screen_w)) - @as(i32, @intCast(layer_pixel_w)), 2) + (layer.offset_x * @as(i32, @intCast(cell_w)));
                ry = @divTrunc(@as(i32, @intCast(screen_h)) - @as(i32, @intCast(layer_pixel_h)), 2) + (layer.offset_y * @as(i32, @intCast(cell_h)));
            },
            .top_left => {
                rx = layer.offset_x * @as(i32, @intCast(cell_w));
                ry = layer.offset_y * @as(i32, @intCast(cell_h));
            },
            .top_right => {
                rx = @as(i32, @intCast(screen_w)) - @as(i32, @intCast(layer_pixel_w)) - (layer.offset_x * @as(i32, @intCast(cell_w)));
                ry = layer.offset_y * @as(i32, @intCast(cell_h));
            },
            .bottom_left => {
                rx = layer.offset_x * @as(i32, @intCast(cell_w));
                ry = @as(i32, @intCast(screen_h)) - @as(i32, @intCast(layer_pixel_h)) - (layer.offset_y * @as(i32, @intCast(cell_h)));
            },
            .bottom_right => {
                rx = @as(i32, @intCast(screen_w)) - @as(i32, @intCast(layer_pixel_w)) - (layer.offset_x * @as(i32, @intCast(cell_w)));
                ry = @as(i32, @intCast(screen_h)) - @as(i32, @intCast(layer_pixel_h)) - (layer.offset_y * @as(i32, @intCast(cell_h)));
            },
            .cursor_relative => {
                rx = cursor_x + (layer.offset_x * @as(i32, @intCast(cell_w)));
                ry = cursor_y + (layer.offset_y * @as(i32, @intCast(cell_h)));
            },
            .flex => {
                rx = layer.offset_x * @as(i32, @intCast(cell_w));
                ry = layer.offset_y * @as(i32, @intCast(cell_h));
            },
        }

        // Clamp inside screen bounds
        if (rx + @as(i32, @intCast(layer_pixel_w)) > @as(i32, @intCast(screen_w))) {
            rx = @max(0, @as(i32, @intCast(screen_w)) - @as(i32, @intCast(layer_pixel_w)));
        }
        if (ry + @as(i32, @intCast(layer_pixel_h)) > @as(i32, @intCast(screen_h))) {
            ry = @max(0, @as(i32, @intCast(screen_h)) - @as(i32, @intCast(layer_pixel_h)));
        }
        if (rx < 0) rx = 0;
        if (ry < 0) ry = 0;

        return Rect{
            .x = rx,
            .y = ry,
            .width = layer_pixel_w,
            .height = layer_pixel_h,
        };
    }

    pub fn hitTest(self: *const Scene, screen_w: u32, screen_h: u32, cursor_x: i32, cursor_y: i32, cell_w: u32, cell_h: u32, gx: i32, gy: i32) ?HitResult {
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            const layer = self.layers.items[i];
            if (!layer.visible) continue;

            const l_rect = computeLayerRect(layer, screen_w, screen_h, cursor_x, cursor_y, cell_w, cell_h);
            if (l_rect.contains(gx, gy)) {
                const lx = gx - l_rect.x;
                const ly = gy - l_rect.y;

                return HitResult{
                    .layer_id = layer.id,
                    .widget_id = findFocusedWidget(layer.children),
                    .local_x = lx,
                    .local_y = ly,
                };
            }
        }
        return null;
    }
};

fn findFocusedWidget(children: []const Widget) ?[]const u8 {
    for (children) |w| {
        if (w.focused and w.id != null) return w.id.?;
        if (w.children.len > 0) {
            if (findFocusedWidget(w.children)) |f| return f;
        }
    }
    return null;
}

fn findFocusedWidgetPtr(children: []Widget) ?*Widget {
    for (children) |*w| {
        if (w.focused) return w;
        if (w.children.len > 0) {
            if (findFocusedWidgetPtr(w.children)) |f| return f;
        }
    }
    return null;
}

fn findFocusedInput(children: []Widget) ?*Widget {
    for (children) |*w| {
        if (w.type == .input and w.focused) return w;
        if (w.children.len > 0) {
            if (findFocusedInput(w.children)) |f| return f;
        }
    }
    for (children) |*w| {
        if (w.type == .input) return w;
        if (w.children.len > 0) {
            if (findFocusedInput(w.children)) |f| return f;
        }
    }
    return null;
}

fn findFirstListOrTable(children: []Widget) ?*Widget {
    for (children) |*w| {
        if (w.type == .list or w.type == .table) return w;
        if (w.children.len > 0) {
            if (findFirstListOrTable(w.children)) |f| return f;
        }
    }
    return null;
}

fn collectFocusable(allocator: std.mem.Allocator, children: []Widget, list: *std.ArrayList(*Widget)) void {
    for (children) |*w| {
        if (w.type == .button or w.type == .input) {
            list.append(allocator, w) catch {};
        }
        if (w.children.len > 0) {
            collectFocusable(allocator, w.children, list);
        }
    }
}

fn cycleFocus(children: []Widget, backward: bool) void {
    const allocator = std.heap.page_allocator;
    var focusable: std.ArrayList(*Widget) = .empty;
    defer focusable.deinit(allocator);
    collectFocusable(allocator, children, &focusable);

    if (focusable.items.len == 0) return;

    var cur_idx: ?usize = null;
    for (focusable.items, 0..) |w, idx| {
        if (w.focused) {
            cur_idx = idx;
            w.focused = false;
            break;
        }
    }

    const next_idx = if (cur_idx) |c| (if (backward) (if (c == 0) focusable.items.len - 1 else c - 1) else (c + 1) % focusable.items.len) else 0;

    focusable.items[next_idx].focused = true;
}
