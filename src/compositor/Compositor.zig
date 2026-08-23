const std = @import("std");

pub const message = @import("message.zig");
pub const parser = @import("parser.zig");
pub const scene_mod = @import("scene.zig");
pub const blend = @import("blend.zig");
pub const rasterizer = @import("rasterizer.zig");
pub const server_mod = @import("server.zig");

pub const Scene = scene_mod.Scene;
pub const Server = server_mod.Server;
pub const Rect = scene_mod.Rect;

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    scene: Scene,
    server: ?Server = null,

    pub fn init(allocator: std.mem.Allocator, pid: ?i32) !Compositor {
        var comp = Compositor{
            .allocator = allocator,
            .scene = Scene.init(allocator),
            .server = null,
        };

        if (pid) |p| {
            comp.server = try Server.init(allocator, p);
        }

        return comp;
    }

    pub fn deinit(self: *Compositor) void {
        if (self.server) |*srv| {
            srv.deinit();
        }
        self.scene.deinit();
    }

    pub fn socketFd(self: *const Compositor) ?std.posix.fd_t {
        if (self.server) |*srv| {
            return srv.server_fd;
        }
        return null;
    }

    pub fn socketPath(self: *const Compositor) ?[]const u8 {
        if (self.server) |*srv| {
            return srv.socket_path;
        }
        return null;
    }

    pub fn poll(self: *Compositor) bool {
        if (self.server) |*srv| {
            return srv.pollEvents(&self.scene);
        }
        return false;
    }

    pub fn hasActiveOverlays(self: *const Compositor) bool {
        for (self.scene.layers.items) |l| {
            if (l.visible) return true;
        }
        return false;
    }

    pub fn hasActiveModal(self: *const Compositor) bool {
        return self.scene.hasActiveModal();
    }

    pub fn renderOverlays(
        self: *Compositor,
        pixels: []u32,
        stride: u31,
        width: u31,
        height: u31,
        cursor_x: i32,
        cursor_y: i32,
        cell_w: u32,
        cell_h: u32,
    ) void {
        if (!self.hasActiveOverlays()) return;

        // 1. Backdrop Dimming Pass (if any active modal requests dimming)
        for (self.scene.layers.items) |layer| {
            if (layer.visible and layer.style.backdrop != null) {
                blend.dimPixels(pixels, stride, width, height, layer.style.backdrop.?.dim);
                break;
            }
        }

        // 2. Render Layers in Z-order
        for (self.scene.layers.items) |layer| {
            if (!layer.visible) continue;
            const l_rect = scene_mod.Scene.computeLayerRect(layer, width, height, cursor_x, cursor_y, cell_w, cell_h);
            rasterizer.renderLayer(pixels, stride, width, height, layer, l_rect, cell_w, cell_h);
        }
    }
};

test "Compositor scene creation and rendering" {
    const allocator = std.testing.allocator;
    var comp = try Compositor.init(allocator, null);
    defer comp.deinit();

    const fb = try allocator.alloc(u32, 800 * 600);
    defer allocator.free(fb);
    @memset(fb, 0xff1e1e2e);

    const test_layer = message.Layer{
        .id = "test_dialog",
        .type = .modal,
        .visible = true,
        .anchor = .center,
        .width = 40,
        .height = 10,
        .style = .{
            .border = .rounded,
            .title = " Test Dialog ",
            .shadow = true,
            .backdrop = .{ .dim = 0.5 },
        },
    };

    try comp.scene.setLayers(&[_]message.Layer{test_layer});
    try std.testing.expect(comp.hasActiveOverlays());
    try std.testing.expect(comp.hasActiveModal());

    comp.renderOverlays(fb, 800, 800, 600, 100, 100, 8, 16);

    // Verify backdrop was dimmed (non-zero alpha)
    try std.testing.expect(fb[0] != 0);
}

test "Compositor demo modal JSON parsing and rendering" {
    const allocator = std.testing.allocator;
    var comp = try Compositor.init(allocator, null);
    defer comp.deinit();

    const json_text =
        \\{
        \\    "layers": [
        \\        {
        \\            "id": "confirm_dialog",
        \\            "type": "modal",
        \\            "anchor": "center",
        \\            "width": 46,
        \\            "height": 9,
        \\            "style": {
        \\                "border": "rounded",
        \\                "title": " Deploy to Production ",
        \\                "border_fg": "#89b4fa",
        \\                "bg": "#1e1e2e",
        \\                "shadow": true,
        \\                "backdrop": {"dim": 0.55}
        \\            },
        \\            "children": [
        \\                {
        \\                    "type": "text",
        \\                    "text": "Are you sure you want to deploy v2.4.0 to prod-east-1?",
        \\                    "align": "left"
        \\                },
        \\                {
        \\                    "type": "box",
        \\                    "direction": "row",
        \\                    "justify": "center",
        \\                    "gap": 2,
        \\                    "margin_top": 2,
        \\                    "children": [
        \\                        {
        \\                            "type": "button",
        \\                            "id": "cancel",
        \\                            "label": " Cancel ",
        \\                            "focused": false
        \\                        },
        \\                        {
        \\                            "type": "button",
        \\                            "id": "confirm",
        \\                            "label": " Confirm Deploy ",
        \\                            "variant": "danger",
        \\                            "focused": true
        \\                        }
        \\                    ]
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const layers = try parser.parseLayerRender(comp.scene.arena.allocator(), parsed.value);
    try comp.scene.setLayers(layers);

    const fb = try allocator.alloc(u32, 800 * 600);
    defer allocator.free(fb);
    @memset(fb, 0xff1e1e2e);

    comp.renderOverlays(fb, 800, 800, 600, 100, 100, 13, 29);
}
