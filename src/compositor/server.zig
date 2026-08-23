const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const scene_mod = @import("scene.zig");
const parser = @import("parser.zig");
const Scene = scene_mod.Scene;

pub const Server = struct {
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    server_fd: posix.fd_t,
    epoll_fd: posix.fd_t,
    client_fds: std.ArrayList(posix.fd_t),
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, pid: i32) !Server {
        var path_buf: [128]u8 = undefined;
        const sock_str = try std.fmt.bufPrint(&path_buf, "/tmp/gtty_{d}.sock", .{pid});
        const socket_path = try allocator.dupeZ(u8, sock_str);

        // Remove any stale socket
        _ = linux.unlink(socket_path.ptr);

        var un: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = [_]u8{0} ** 108,
        };
        const copy_len = @min(socket_path.len, un.path.len - 1);
        @memcpy(un.path[0..copy_len], socket_path[0..copy_len]);
        un.path[copy_len] = 0;

        const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
        const socket_fd: posix.fd_t = @intCast(sock_rc);
        errdefer _ = linux.close(socket_fd);

        const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + copy_len + 1);
        const bind_rc = linux.bind(socket_fd, @ptrCast(&un), addr_len);
        if (linux.errno(bind_rc) != .SUCCESS) return error.BindFailed;

        const listen_rc = linux.listen(socket_fd, 16);
        if (linux.errno(listen_rc) != .SUCCESS) return error.ListenFailed;

        const epoll_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(epoll_rc) != .SUCCESS) return error.EpollFailed;
        const epoll_fd: posix.fd_t = @intCast(epoll_rc);
        errdefer _ = linux.close(epoll_fd);

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = linux.epoll_data{ .fd = socket_fd },
        };
        _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, socket_fd, &ev);

        return Server{
            .allocator = allocator,
            .socket_path = socket_path,
            .server_fd = socket_fd,
            .epoll_fd = epoll_fd,
            .client_fds = .empty,
            .dirty = false,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.client_fds.items) |cfd| {
            _ = linux.close(cfd);
        }
        self.client_fds.deinit(self.allocator);
        _ = linux.close(self.server_fd);
        _ = linux.close(self.epoll_fd);
        _ = linux.unlink(self.socket_path.ptr);
        self.allocator.free(self.socket_path);
    }

    pub fn pollEvents(self: *Server, scene: *Scene) bool {
        self.acceptNewClients();
        self.readClientData(scene);
        const was_dirty = self.dirty;
        self.dirty = false;
        return was_dirty;
    }

    fn acceptNewClients(self: *Server) void {
        while (true) {
            const client_rc = linux.accept4(self.server_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(client_rc) != .SUCCESS) break;
            const client_fd: posix.fd_t = @intCast(client_rc);
            self.client_fds.append(self.allocator, client_fd) catch {
                _ = linux.close(client_fd);
                break;
            };

            var client_ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.RDHUP,
                .data = linux.epoll_data{ .fd = client_fd },
            };
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &client_ev);
        }
    }

    fn readClientData(self: *Server, scene: *Scene) void {
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
                _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
                _ = linux.close(fd);
                _ = self.client_fds.orderedRemove(i);
                continue;
            }

            self.handleMessage(scene, fd, buf[0..bytes_read]);
            i += 1;
        }
    }

    fn handleMessage(self: *Server, scene: *Scene, fd: posix.fd_t, raw_data: []const u8) void {
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
                    scene.clear();
                    if (parser.parseLayerRender(scene.arena.allocator(), params_val)) |layers| {
                        scene.setLayers(layers) catch {};
                        self.dirty = true;
                        self.sendSuccess(fd, id_num);
                    } else |_| {
                        self.sendError(fd, id_num, "Invalid layer.render params");
                    }
                } else if (std.mem.eql(u8, method, "layer.clear") or std.mem.eql(u8, method, "surface.destroy")) {
                    scene.clear();
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
        if (id) |req_id| {
            if (std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"ok\"}}}}\n", .{req_id})) |msg_str| {
                _ = linux.write(fd, msg_str.ptr, msg_str.len);
            } else |_| {}
        } else {
            const static_msg = "{\"jsonrpc\":\"2.0\",\"result\":{\"status\":\"ok\"}}\n";
            _ = linux.write(fd, static_msg.ptr, static_msg.len);
        }
    }

    fn sendError(self: *Server, fd: posix.fd_t, id: ?u64, err_msg: []const u8) void {
        _ = self;
        var resp_buf: [256]u8 = undefined;
        if (id) |req_id| {
            if (std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"message\":\"{s}\"}}}}\n", .{ req_id, err_msg })) |msg_str| {
                _ = linux.write(fd, msg_str.ptr, msg_str.len);
            } else |_| {}
        } else {
            if (std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"error\":{{\"message\":\"{s}\"}}}}\n", .{err_msg})) |msg_str| {
                _ = linux.write(fd, msg_str.ptr, msg_str.len);
            } else |_| {}
        }
    }

    pub fn broadcastEvent(self: *Server, method: []const u8, params_json: []const u8) void {
        var msg_buf: [1024]u8 = undefined;
        const msg_str = std.fmt.bufPrint(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, params_json }) catch return;
        for (self.client_fds.items) |cfd| {
            _ = linux.write(cfd, msg_str.ptr, msg_str.len);
        }
    }
};
