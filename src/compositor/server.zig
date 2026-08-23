const std = @import("std");
const posix = std.posix;
const scene_mod = @import("scene.zig");
const parser = @import("parser.zig");
const Scene = scene_mod.Scene;

pub const Server = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    server_fd: posix.fd_t,
    client_fds: std.ArrayList(posix.fd_t),
    scene: *Scene,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, scene: *Scene, pid: i32) !Server {
        var path_buf: [128]u8 = undefined;
        const sock_str = try std.fmt.bufPrint(&path_buf, "/tmp/gtty_{d}.sock", .{pid});
        const socket_path = try allocator.dupe(u8, sock_str);

        // Remove any stale socket
        _ = posix.unlink(socket_path) catch {};

        var addr = try std.net.Address.initUnix(socket_path);
        const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(socket_fd);

        try posix.bind(socket_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(socket_fd, 16);

        return Server{
            .allocator = allocator,
            .socket_path = socket_path,
            .server_fd = socket_fd,
            .client_fds = std.ArrayList(posix.fd_t).init(allocator),
            .scene = scene,
            .dirty = false,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.client_fds.items) |cfd| {
            posix.close(cfd);
        }
        self.client_fds.deinit();
        posix.close(self.server_fd);
        _ = posix.unlink(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
    }

    pub fn pollEvents(self: *Server) bool {
        self.acceptNewClients();
        self.readClientData();
        const was_dirty = self.dirty;
        self.dirty = false;
        return was_dirty;
    }

    fn acceptNewClients(self: *Server) void {
        while (true) {
            const client_fd = posix.accept(self.server_fd, null, null, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            self.client_fds.append(client_fd) catch {
                posix.close(client_fd);
                break;
            };
        }
    }

    fn readClientData(self: *Server) void {
        var i: usize = 0;
        var buf: [8192]u8 = undefined;

        while (i < self.client_fds.items.len) {
            const fd = self.client_fds.items[i];
            const bytes_read = posix.read(fd, &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    i += 1;
                    continue;
                },
                else => 0,
            };

            if (bytes_read == 0) {
                posix.close(fd);
                _ = self.client_fds.orderedRemove(i);
                continue;
            }

            self.handleMessage(fd, buf[0..bytes_read]);
            i += 1;
        }
    }

    fn handleMessage(self: *Server, fd: posix.fd_t, raw_data: []const u8) void {
        var it = std.mem.splitScalar(u8, raw_data, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch {
                self.sendError(fd, null, "Parse error");
                continue;
            };
            defer parsed.deinit();

            const root = parsed.value;
            const method_val = switch (root) {
                .object => |obj| obj.get("method"),
                else => null,
            };
            const id_val = switch (root) {
                .object => |obj| obj.get("id"),
                else => null,
            };

            const id_num: ?u64 = if (id_val != null and id_val.? == .integer) @intCast(id_val.?.integer) else null;

            if (method_val != null and method_val.? == .string) {
                const method = method_val.?.string;
                if (std.mem.eql(u8, method, "layer.render") or std.mem.eql(u8, method, "surface.render")) {
                    const params_val = switch (root) {
                        .object => |obj| obj.get("params") orelse root,
                        else => root,
                    };
                    if (parser.parseLayerRender(self.allocator, params_val)) |layers| {
                        self.scene.setLayers(layers) catch {};
                        self.dirty = true;
                        self.sendSuccess(fd, id_num);
                    } else |_| {
                        self.sendError(fd, id_num, "Invalid layer.render params");
                    }
                } else if (std.mem.eql(u8, method, "layer.clear") or std.mem.eql(u8, method, "surface.destroy")) {
                    self.scene.clear();
                    self.dirty = true;
                    self.sendSuccess(fd, id_num);
                } else {
                    self.sendSuccess(fd, id_num);
                }
            } else {
                self.sendSuccess(fd, id_num);
            }
        }
    }

    fn sendSuccess(self: *Server, fd: posix.fd_t, id: ?u64) void {
        _ = self;
        var resp_buf: [128]u8 = undefined;
        const msg_str = if (id) |req_id|
            std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\"}}}\n", .{req_id}) catch return
        else
            std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"result\":{{\"status\":\"ok\"}}}\n", .{}) catch return;

        _ = posix.write(fd, msg_str) catch {};
    }

    fn sendError(self: *Server, fd: posix.fd_t, id: ?u64, err_msg: []const u8) void {
        _ = self;
        var resp_buf: [256]u8 = undefined;
        const msg_str = if (id) |req_id|
            std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"message\":\"{s}\"}}}\n", .{ req_id, err_msg }) catch return
        else
            std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"error\":{{\"message\":\"{s}\"}}}\n", .{err_msg}) catch return;

        _ = posix.write(fd, msg_str) catch {};
    }
};
