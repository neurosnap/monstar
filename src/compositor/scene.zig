const std = @import("std");
const msg = @import("message.zig");
const Layer = msg.Layer;
const Widget = msg.Widget;
const Anchor = msg.Anchor;

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
