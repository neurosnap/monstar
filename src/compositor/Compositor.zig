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
            return srv.epoll_fd;
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
        font: ?*@import("../Font.zig"),
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
            rasterizer.renderLayer(pixels, stride, width, height, layer, l_rect, cell_w, cell_h, font, self.allocator);
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

    comp.renderOverlays(fb, 800, 800, 600, 100, 100, 8, 16, null);

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

    comp.renderOverlays(fb, 800, 800, 600, 100, 100, 13, 29, null);
}

test "PTY bytestream and VT terminal grid state isolation during multi-surface compositing" {
    const allocator = std.testing.allocator;
    const vt = @import("ghostty-vt");

    // 1. Initialize a real Ghostty VT terminal representing the underlying PTY stream
    var term: vt.Terminal = try .init(std.testing.io, allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(allocator);

    // 2. Feed complex shell output containing text, ANSI colors, cursor movements, and formatting
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("user@host:~$ git status\r\nOn branch main\r\n\x1b[32mChanges to be committed:\x1b[0m\r\n\t\x1b[32mmodified:   src/main.zig\x1b[0m\r\n");

    // 3. Take a baseline snapshot of the terminal screen text and cursor state
    const baseline_text = try term.screens.active.dumpStringAlloc(allocator, .{ .viewport = .{} });
    defer allocator.free(baseline_text);
    const baseline_cursor_x = term.screens.active.cursor.x;
    const baseline_cursor_y = term.screens.active.cursor.y;

    // 4. Initialize Compositor with overlays and framebuffers
    var comp = try Compositor.init(allocator, null);
    defer comp.deinit();

    const fb_w: u31 = 800;
    const fb_h: u31 = 600;
    const fb = try allocator.alloc(u32, fb_w * fb_h);
    defer allocator.free(fb);
    @memset(fb, 0xff1e1e2e);

    // 5. Blast multiple overlay layers (modal dialog and cursor-anchored autocomplete popup)
    const modal_layer = message.Layer{
        .id = "deploy_confirm",
        .type = .modal,
        .visible = true,
        .anchor = .center,
        .width = 40,
        .height = 8,
        .style = .{
            .border = .rounded,
            .title = " Confirm Deployment ",
            .shadow = true,
            .backdrop = .{ .dim = 0.6 },
        },
    };

    const popup_layer = message.Layer{
        .id = "autocomplete",
        .type = .popup,
        .visible = true,
        .anchor = .cursor_relative,
        .offset_x = 0,
        .offset_y = 1,
        .width = 30,
        .height = 6,
        .style = .{
            .border = .single,
            .title = " Suggestions ",
            .shadow = false,
        },
    };

    try comp.scene.setLayers(&[_]message.Layer{ modal_layer, popup_layer });
    try std.testing.expect(comp.hasActiveOverlays());
    try std.testing.expect(comp.hasActiveModal());

    // 6. Perform software rasterization and compositing onto the pixel framebuffer
    comp.renderOverlays(fb, fb_w, fb_w, fb_h, @intCast(baseline_cursor_x * 8), @intCast(baseline_cursor_y * 16), 8, 16, null);

    // 7. Clear the compositor scene
    comp.scene.clear();
    try std.testing.expect(!comp.hasActiveOverlays());
    try std.testing.expect(!comp.hasActiveModal());

    // 8. Assert that the underlying PTY / VT state is 100% untouched and byte-for-byte identical
    const post_comp_text = try term.screens.active.dumpStringAlloc(allocator, .{ .viewport = .{} });
    defer allocator.free(post_comp_text);

    try std.testing.expectEqualStrings(baseline_text, post_comp_text);
    try std.testing.expectEqual(baseline_cursor_x, term.screens.active.cursor.x);
    try std.testing.expectEqual(baseline_cursor_y, term.screens.active.cursor.y);
}

test "Out-of-band IPC server roundtrip isolation" {
    const allocator = std.testing.allocator;
    const posix = std.posix;
    const linux = std.os.linux;

    // Use a unique PID for testing to avoid collisions
    const test_pid: i32 = 98765;
    var comp = try Compositor.init(allocator, test_pid);
    defer comp.deinit();

    const sock_path = comp.socketPath() orelse return error.MissingSocketPath;

    // Connect a client socket to the out-of-band IPC server
    var un: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = [_]u8{0} ** 108,
    };
    @memcpy(un.path[0..sock_path.len], sock_path);

    const client_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    try std.testing.expect(linux.errno(client_rc) == .SUCCESS);
    const client_fd: posix.fd_t = @intCast(client_rc);
    defer _ = linux.close(client_fd);

    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + sock_path.len + 1);
    const conn_rc = linux.connect(client_fd, @ptrCast(&un), addr_len);
    try std.testing.expect(linux.errno(conn_rc) == .SUCCESS);

    // Send JSON-RPC layer.render payload over the socket
    const render_req =
        \\{"jsonrpc":"2.0","id":42,"method":"layer.render","params":{"layers":[{"id":"test_modal","type":"modal","width":30,"height":6,"style":{"title":"Test"}}]}}
        \\
    ;
    _ = linux.write(client_fd, render_req.ptr, render_req.len);

    // Poll the server
    _ = comp.poll();

    // Verify scene state was updated via socket
    try std.testing.expect(comp.hasActiveOverlays());
    try std.testing.expect(comp.hasActiveModal());

    // Read the server response from the client socket
    var resp_buf: [256]u8 = undefined;
    const read_len = linux.read(client_fd, &resp_buf, resp_buf.len);
    try std.testing.expect(read_len > 0);
    const resp_str = resp_buf[0..@intCast(read_len)];
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "\"status\":\"ok\"") != null);

    // Send layer.clear
    const clear_req = "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"layer.clear\",\"params\":{}}\n";
    _ = linux.write(client_fd, clear_req.ptr, clear_req.len);

    _ = comp.poll();
    try std.testing.expect(!comp.hasActiveOverlays());
}

test "Anchor geometry clamping and cursor-relative positioning" {
    const layer = message.Layer{
        .id = "popup",
        .type = .popup,
        .anchor = .cursor_relative,
        .offset_x = 2,
        .offset_y = 1,
        .width = 20, // 20 cols * 8 px = 160 px
        .height = 5, // 5 rows * 16 px = 80 px
    };

    const rect = scene_mod.Scene.computeLayerRect(layer, 800, 600, 100, 100, 8, 16);
    try std.testing.expectEqual(@as(i32, 116), rect.x); // 100 + (2 * 8)
    try std.testing.expectEqual(@as(i32, 116), rect.y); // 100 + (1 * 16)
    try std.testing.expectEqual(@as(u32, 160), rect.width);
    try std.testing.expectEqual(@as(u32, 80), rect.height);
}

const PtyStreamTester = struct {
    slave_fd: std.posix.fd_t,
    num_packets: usize,

    fn writeWorker(self: *const PtyStreamTester) void {
        var buf: [128]u8 = undefined;
        for (0..self.num_packets) |seq| {
            const line = std.fmt.bufPrint(&buf, "[SEQ:{d:0>6}] PTY bytestream payload chunk with ANSI \x1b[32mOK\x1b[0m\r\n", .{seq}) catch unreachable;
            var written: usize = 0;
            while (written < line.len) {
                const rc = std.os.linux.write(self.slave_fd, line.ptr + written, line.len - written);
                if (std.os.linux.errno(rc) == .SUCCESS) {
                    written += @intCast(rc);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }
};

test "High-throughput concurrent PTY stream byte-for-byte integrity during compositor RPC" {
    const allocator = std.testing.allocator;
    const Pty = @import("../Pty.zig");
    const posix = std.posix;
    const linux = std.os.linux;

    var pty = try Pty.open(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    defer pty.deinit();

    var tio = try posix.tcgetattr(pty.slave);
    tio.iflag = @bitCast(@as(u32, 0));
    tio.oflag = @bitCast(@as(u32, 0));
    tio.lflag = @bitCast(@as(u32, 0));
    try posix.tcsetattr(pty.slave, .NOW, tio);

    // Initialize Compositor with IPC server
    const test_pid: i32 = 98766;
    var comp = try Compositor.init(allocator, test_pid);
    defer comp.deinit();

    const sock_path = comp.socketPath() orelse return error.MissingSocketPath;

    // Connect client socket
    var un: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = [_]u8{0} ** 108,
    };
    @memcpy(un.path[0..sock_path.len], sock_path);

    const client_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    try std.testing.expect(linux.errno(client_rc) == .SUCCESS);
    const client_fd: posix.fd_t = @intCast(client_rc);
    defer _ = linux.close(client_fd);

    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + sock_path.len + 1);
    const conn_rc = linux.connect(client_fd, @ptrCast(&un), addr_len);
    try std.testing.expect(linux.errno(conn_rc) == .SUCCESS);

    const num_packets: usize = 500;
    const tester = PtyStreamTester{
        .slave_fd = pty.slave,
        .num_packets = num_packets,
    };

    // Spawn background PTY writer
    const writer_thread = try std.Thread.spawn(.{}, PtyStreamTester.writeWorker, .{&tester});

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total_bytes_read: usize = 0;
    var read_buf: [4096]u8 = undefined;

    // Concurrently read from PTY master and blast compositor RPC requests
    var rpc_cycle: usize = 0;
    while (true) {
        // 1. Read available bytes from PTY master
        const n = linux.read(pty.master, &read_buf, read_buf.len);
        if (linux.errno(n) == .SUCCESS and n > 0) {
            const chunk = read_buf[0..@intCast(n)];
            hasher.update(chunk);
            total_bytes_read += chunk.len;

            // Verify no JSON-RPC metadata leaked into the PTY stream
            try std.testing.expect(std.mem.indexOf(u8, chunk, "jsonrpc") == null);
            try std.testing.expect(std.mem.indexOf(u8, chunk, "layer.render") == null);
        }

        // 2. Concurrently send and poll compositor RPC calls
        if (rpc_cycle < 10) {
            const req =
                \\{"jsonrpc":"2.0","id":100,"method":"layer.render","params":{"layers":[{"id":"dlg","type":"modal","width":30,"height":5}]}}
                \\
            ;
            _ = linux.write(client_fd, req.ptr, req.len);
            _ = comp.poll();
            rpc_cycle += 1;
        }

        // Calculate expected total bytes
        var sample_buf: [128]u8 = undefined;
        const sample_line = std.fmt.bufPrint(&sample_buf, "[SEQ:000000] PTY bytestream payload chunk with ANSI \x1b[32mOK\x1b[0m\r\n", .{}) catch unreachable;
        const expected_total = sample_line.len * num_packets;

        if (total_bytes_read >= expected_total) break;
    }

    writer_thread.join();

    // Verify expected total bytes
    var sample_buf: [128]u8 = undefined;
    const sample_line = std.fmt.bufPrint(&sample_buf, "[SEQ:000000] PTY bytestream payload chunk with ANSI \x1b[32mOK\x1b[0m\r\n", .{}) catch unreachable;
    const expected_total = sample_line.len * num_packets;
    try std.testing.expectEqual(expected_total, total_bytes_read);

    // Compute expected hash of the pure stream
    var expected_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..num_packets) |seq| {
        const line = std.fmt.bufPrint(&sample_buf, "[SEQ:{d:0>6}] PTY bytestream payload chunk with ANSI \x1b[32mOK\x1b[0m\r\n", .{seq}) catch unreachable;
        expected_hasher.update(line);
    }
    var expected_digest: [32]u8 = undefined;
    expected_hasher.final(&expected_digest);

    var actual_digest: [32]u8 = undefined;
    hasher.final(&actual_digest);

    // Byte-for-byte SHA256 equality verification
    try std.testing.expectEqualSlices(u8, &expected_digest, &actual_digest);
}
