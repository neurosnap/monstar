//! Sub-command implementation for `monstar ui ...`
//!
//! Provides CLI access to native dialogs, base-layer inspection,
//! overlay clearing, and shell autocompletion augmentation.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        printUiUsage();
        return;
    }

    const subcmd = args[0];
    if (std.mem.eql(u8, subcmd, "dialog")) {
        return runDialog(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcmd, "inspect")) {
        return runInspect(allocator);
    } else if (std.mem.eql(u8, subcmd, "clear")) {
        return runClear(allocator);
    } else if (std.mem.eql(u8, subcmd, "autocomplete")) {
        return runAutocomplete(allocator);
    } else {
        printUiUsage();
        std.process.exit(1);
    }
}

fn printUiUsage() void {
    const usage =
        \\monstar ui - Native Multi-Surface UI & Augmentation Toolkit
        \\
        \\Usage:
        \\  monstar ui dialog confirm <question> [--danger]
        \\  monstar ui dialog select <title> [--items <item1,item2,...>]
        \\  monstar ui dialog input <title> [--placeholder <text>]
        \\  monstar ui inspect
        \\  monstar ui autocomplete
        \\  monstar ui clear
        \\
        \\Examples:
        \\  if monstar ui dialog confirm "Deploy to staging?" --danger; then ./deploy.sh; fi
        \\  branch=$(monstar ui dialog select "Pick Branch" --items "main,staging,dev")
        \\  msg=$(monstar ui dialog input "Commit message:" --placeholder "feat: ...")
        \\  monstar ui inspect
        \\  monstar ui autocomplete
        \\
    ;
    _ = linux.write(std.posix.STDOUT_FILENO, usage.ptr, usage.len);
}

fn tryConnectSocket(path: []const u8) ?posix.fd_t {
    var un: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = [_]u8{0} ** 108,
    };
    const copy_len = @min(path.len, un.path.len - 1);
    @memcpy(un.path[0..copy_len], path[0..copy_len]);
    un.path[copy_len] = 0;

    const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (linux.errno(sock_rc) != .SUCCESS) return null;
    const fd: posix.fd_t = @intCast(sock_rc);

    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + copy_len + 1);
    const conn_rc = linux.connect(fd, @ptrCast(&un), addr_len);
    if (linux.errno(conn_rc) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn connectGtty(allocator: std.mem.Allocator) !posix.fd_t {
    _ = allocator;
    // 1. Try GTTY_SOCK environment variable
    if (std.c.getenv("GTTY_SOCK")) |env_ptr| {
        const sock_path = std.mem.span(env_ptr);
        if (tryConnectSocket(sock_path)) |fd| return fd;
    }

    // 2. Try parent PID socket
    var path_buf: [128]u8 = undefined;
    const ppid = linux.getppid();
    if (std.fmt.bufPrintZ(&path_buf, "/tmp/gtty_{d}.sock", .{ppid})) |ppid_path| {
        if (tryConnectSocket(ppid_path)) |fd| return fd;
    } else |_| {}

    // 3. Scan /tmp for any active gtty_*.sock
    if (std.c.opendir("/tmp")) |dir| {
        defer _ = std.c.closedir(dir);
        while (std.c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            if (std.mem.startsWith(u8, name, "gtty_") and std.mem.endsWith(u8, name, ".sock")) {
                if (std.fmt.bufPrintZ(&path_buf, "/tmp/{s}", .{name})) |test_path| {
                    if (tryConnectSocket(test_path)) |fd| return fd;
                } else |_| {}
            }
        }
    }

    return error.GttySockNotSet;
}

fn runDialog(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) {
        printUiUsage();
        std.process.exit(1);
    }
    const dialog_type = args[0];
    if (std.mem.eql(u8, dialog_type, "confirm")) {
        const question = if (args.len > 1) args[1] else "Confirm Action?";
        var danger = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--danger")) danger = true;
        }
        return doConfirmDialog(allocator, question, danger);
    } else if (std.mem.eql(u8, dialog_type, "select")) {
        const title = if (args.len > 1) args[1] else "Select an Option";
        var items_str: []const u8 = "Option 1,Option 2,Option 3";
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            if (std.mem.eql(u8, args[idx], "--items") and idx + 1 < args.len) {
                items_str = args[idx + 1];
                idx += 1;
            }
        }
        return doSelectDialog(allocator, title, items_str);
    } else if (std.mem.eql(u8, dialog_type, "input")) {
        const title = if (args.len > 1) args[1] else "Enter Input";
        var placeholder: []const u8 = "";
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            if (std.mem.eql(u8, args[idx], "--placeholder") and idx + 1 < args.len) {
                placeholder = args[idx + 1];
                idx += 1;
            }
        }
        return doInputDialog(allocator, title, placeholder);
    }
}

fn doConfirmDialog(allocator: std.mem.Allocator, question: []const u8, danger: bool) !void {
    const fd = try connectGtty(allocator);
    defer _ = linux.close(fd);

    const btn_variant = if (danger) "danger" else "primary";
    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"layer.render","params":{{"layers":[{{"id":"cli_confirm","type":"modal","anchor":"center","width":46,"height":8,"style":{{"border":"rounded","title":" Confirmation ","border_fg":"#89b4fa","bg":"#1e1e2e","shadow":true,"backdrop":{{"dim":0.5}}}},"children":[{{"type":"text","text":"{s}","align":"center","margin_top":1}},{{"type":"box","direction":"row","justify":"center","gap":2,"margin_top":1,"children":[{{"type":"button","id":"cancel","label":" Cancel ","focused":false}},{{"type":"button","id":"confirm","label":" Confirm ","variant":"{s}","focused":true}}]}}]}}]}}
        \\
    , .{ question, btn_variant });
    defer allocator.free(req);

    _ = linux.write(fd, req.ptr, req.len);

    var buf: [2048]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (n <= 0) break;
        const msg = buf[0..@intCast(n)];
        if (std.mem.indexOf(u8, msg, "event.click") != null) {
            if (std.mem.indexOf(u8, msg, "\"confirm\"") != null) {
                sendClear(fd);
                std.process.exit(0);
            } else {
                sendClear(fd);
                std.process.exit(1);
            }
        } else if (std.mem.indexOf(u8, msg, "event.dismiss") != null) {
            sendClear(fd);
            std.process.exit(1);
        }
    }
}

fn doSelectDialog(allocator: std.mem.Allocator, title: []const u8, items_str: []const u8) !void {
    const fd = try connectGtty(allocator);
    defer _ = linux.close(fd);

    var items_json: std.ArrayList(u8) = .empty;
    defer items_json.deinit(allocator);
    try items_json.appendSlice(allocator, "[");

    var it = std.mem.splitScalar(u8, items_str, ',');
    var first = true;
    var count: usize = 0;
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (trimmed.len == 0) continue;
        if (!first) try items_json.appendSlice(allocator, ",");
        first = false;
        count += 1;
        try items_json.append(allocator, '"');
        try items_json.appendSlice(allocator, trimmed);
        try items_json.append(allocator, '"');
    }
    try items_json.appendSlice(allocator, "]");

    const height = @max(7, @min(20, count + 5));
    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"layer.render","params":{{"layers":[{{"id":"cli_select","type":"modal","anchor":"center","width":48,"height":{d},"style":{{"border":"rounded","title":" {s} ","border_fg":"#89b4fa","bg":"#1e1e2e","shadow":true,"backdrop":{{"dim":0.5}}}},"children":[{{"type":"list","id":"select_list","selected_index":0,"items":{s}}}]}}]}}
        \\
    , .{ height, title, items_json.items });
    defer allocator.free(req);

    _ = linux.write(fd, req.ptr, req.len);

    var buf: [2048]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (n <= 0) break;
        const msg = buf[0..@intCast(n)];
        if (std.mem.indexOf(u8, msg, "event.submit") != null) {
            if (std.mem.indexOf(u8, msg, "\"value\":\"")) |v_start| {
                const val_body = msg[v_start + 9 ..];
                if (std.mem.indexOf(u8, val_body, "\"")) |v_end| {
                    const result_val = val_body[0..v_end];
                    _ = linux.write(std.posix.STDOUT_FILENO, result_val.ptr, result_val.len);
                    _ = linux.write(std.posix.STDOUT_FILENO, "\n", 1);
                }
            }
            sendClear(fd);
            std.process.exit(0);
        } else if (std.mem.indexOf(u8, msg, "event.dismiss") != null) {
            sendClear(fd);
            std.process.exit(1);
        }
    }
}

fn doInputDialog(allocator: std.mem.Allocator, title: []const u8, placeholder: []const u8) !void {
    const fd = try connectGtty(allocator);
    defer _ = linux.close(fd);

    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"layer.render","params":{{"layers":[{{"id":"cli_input","type":"modal","anchor":"center","width":48,"height":7,"style":{{"border":"rounded","title":" {s} ","border_fg":"#89b4fa","bg":"#1e1e2e","shadow":true,"backdrop":{{"dim":0.5}}}},"children":[{{"type":"input","id":"prompt_input","placeholder":"{s}","value":"","focused":true}}]}}]}}
        \\
    , .{ title, placeholder });
    defer allocator.free(req);

    _ = linux.write(fd, req.ptr, req.len);

    var buf: [2048]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (n <= 0) break;
        const msg = buf[0..@intCast(n)];
        if (std.mem.indexOf(u8, msg, "event.submit") != null) {
            if (std.mem.indexOf(u8, msg, "\"value\":\"")) |v_start| {
                const val_body = msg[v_start + 9 ..];
                if (std.mem.indexOf(u8, val_body, "\"")) |v_end| {
                    const result_val = val_body[0..v_end];
                    _ = linux.write(std.posix.STDOUT_FILENO, result_val.ptr, result_val.len);
                    _ = linux.write(std.posix.STDOUT_FILENO, "\n", 1);
                }
            }
            sendClear(fd);
            std.process.exit(0);
        } else if (std.mem.indexOf(u8, msg, "event.dismiss") != null) {
            sendClear(fd);
            std.process.exit(1);
        }
    }
}

fn runInspect(allocator: std.mem.Allocator) !void {
    const fd = try connectGtty(allocator);
    defer _ = linux.close(fd);

    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal.inspect\"}\n";
    _ = linux.write(fd, req.ptr, req.len);

    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (n > 0) {
        const resp = buf[0..@intCast(n)];
        _ = linux.write(std.posix.STDOUT_FILENO, resp.ptr, resp.len);
    }
}

fn runClear(allocator: std.mem.Allocator) !void {
    const fd = try connectGtty(allocator);
    defer _ = linux.close(fd);
    sendClear(fd);
}

fn sendClear(fd: posix.fd_t) void {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"layer.clear\"}\n";
    _ = linux.write(fd, req.ptr, req.len);
    var ack_buf: [256]u8 = undefined;
    _ = linux.read(fd, &ack_buf, ack_buf.len);
}

fn runAutocomplete(allocator: std.mem.Allocator) !void {
    const fd = try connectGtty(allocator);
    defer _ = linux.close(fd);

    const msg = "[Monstar UI] Shell Autocomplete daemon active on $GTTY_SOCK.\n";
    _ = linux.write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);

    var last_token_buf: [128]u8 = undefined;
    var last_token_len: usize = 0;
    var popup_active = false;

    var buf: [4096]u8 = undefined;

    while (true) {
        // Query inspection
        const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal.inspect\"}\n";
        _ = linux.write(fd, req.ptr, req.len);

        const n = linux.read(fd, &buf, buf.len);
        if (n > 0) {
            const resp = buf[0..@intCast(n)];
            if (std.mem.indexOf(u8, resp, "\"line_prefix\":\"")) |p_start| {
                const body = resp[p_start + 15 ..];
                if (std.mem.indexOf(u8, body, "\"")) |p_end| {
                    const prefix = body[0..p_end];
                    const token = extractCommandToken(prefix);
                    if (!std.mem.eql(u8, token, last_token_buf[0..last_token_len])) {
                        const copy_len = @min(token.len, last_token_buf.len);
                        @memcpy(last_token_buf[0..copy_len], token[0..copy_len]);
                        last_token_len = copy_len;

                        if (token.len >= 1) {
                            try renderAutoCompletions(allocator, fd, prefix);
                            popup_active = true;
                        } else if (popup_active) {
                            sendClear(fd);
                            popup_active = false;
                        }
                    }
                }
            } else if (std.mem.indexOf(u8, resp, "event.submit") != null) {
                if (std.mem.indexOf(u8, resp, "\"value\":\"")) |v_start| {
                    const val_body = resp[v_start + 9 ..];
                    if (std.mem.indexOf(u8, val_body, "\"")) |v_end| {
                        const result_val = val_body[0..v_end];
                        // Write completed command to PTY and clear popup
                        const write_req = try std.fmt.allocPrint(allocator,
                            \\{{"jsonrpc":"2.0","id":3,"method":"terminal.write","params":{{"data":"\x15{s}\n"}}}}
                            \\
                        , .{result_val});
                        defer allocator.free(write_req);
                        _ = linux.write(fd, write_req.ptr, write_req.len);
                        var ack_buf: [256]u8 = undefined;
                        _ = linux.read(fd, &ack_buf, ack_buf.len);
                        sendClear(fd);
                        popup_active = false;
                    }
                }
            } else if (std.mem.indexOf(u8, resp, "event.dismiss") != null) {
                sendClear(fd);
                popup_active = false;
            }
        }

        // Sleep 40ms
        var req_ts = linux.timespec{ .sec = 0, .nsec = 40 * 1000 * 1000 };
        _ = linux.nanosleep(&req_ts, null);
    }
}

fn extractCommandToken(prefix: []const u8) []const u8 {
    var p = std.mem.trim(u8, prefix, " \t\r\n");
    const prompt_delims = [_][]const u8{
        "▸",
        "❯",
        "➜",
        "→",
        "»",
        "$",
        "#",
        ">",
        "%",
        "λ",
        ":",
    };
    for (prompt_delims) |delim| {
        if (std.mem.lastIndexOf(u8, p, delim)) |idx| {
            p = p[idx + delim.len ..];
            p = std.mem.trim(u8, p, " \t\r\n");
        }
    }
    return p;
}

fn renderAutoCompletions(allocator: std.mem.Allocator, fd: posix.fd_t, prefix: []const u8) !void {
    const token = extractCommandToken(prefix);
    if (token.len == 0) {
        sendClear(fd);
        return;
    }

    // Generate context-aware suggestions
    const suggestions = [_][]const u8{
        "git status",
        "git diff",
        "git log --oneline --graph",
        "git commit -m \"...\"",
        "git push origin main",
        "git pull origin main",
        "git checkout main",
        "git branch",
        "git add .",
        "zig build",
        "zig build test",
        "zig build run",
        "cargo build --release",
        "cargo test",
        "cargo run",
        "monstar ui dialog confirm \"Deploy?\"",
        "monstar ui dialog select \"Pick Branch\"",
        "monstar ui inspect",
        "monstar ui clear",
        "ls -la",
        "top",
    };

    var matched: std.ArrayList([]const u8) = .empty;
    defer matched.deinit(allocator);

    var token_lower_buf: [128]u8 = undefined;
    const token_lower_len = @min(token.len, token_lower_buf.len);
    for (token[0..token_lower_len], 0..) |c, i| {
        token_lower_buf[i] = std.ascii.toLower(c);
    }
    const token_lower = token_lower_buf[0..token_lower_len];

    for (suggestions) |s| {
        var s_lower_buf: [128]u8 = undefined;
        const s_lower_len = @min(s.len, s_lower_buf.len);
        for (s[0..s_lower_len], 0..) |c, i| {
            s_lower_buf[i] = std.ascii.toLower(c);
        }
        const s_lower = s_lower_buf[0..s_lower_len];

        if (std.mem.indexOf(u8, s_lower, token_lower) != null or std.mem.startsWith(u8, s_lower, token_lower)) {
            try matched.append(allocator, s);
        }
    }

    if (matched.items.len == 0) {
        sendClear(fd);
        return;
    }

    var items_json: std.ArrayList(u8) = .empty;
    defer items_json.deinit(allocator);
    try items_json.appendSlice(allocator, "[");
    for (matched.items, 0..) |m, i| {
        if (i > 0) try items_json.appendSlice(allocator, ",");
        try items_json.append(allocator, '"');
        try items_json.appendSlice(allocator, m);
        try items_json.append(allocator, '"');
    }
    try items_json.appendSlice(allocator, "]");

    const height = @max(5, @min(10, matched.items.len + 3));
    const render_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"layer.render","params":{{"layers":[{{"id":"ac_popup","type":"popup","anchor":"cursor_relative","offset_x":0,"offset_y":1,"width":36,"height":{d},"style":{{"border":"rounded","title":" Suggestions ","border_fg":"#a6e3a1","bg":"#181825","shadow":true}},"children":[{{"type":"list","id":"ac_list","selected_index":0,"items":{s}}}]}}]}}
        \\
    , .{ height, items_json.items });
    defer allocator.free(render_req);

    _ = linux.write(fd, render_req.ptr, render_req.len);
    var ack_buf: [256]u8 = undefined;
    _ = linux.read(fd, &ack_buf, ack_buf.len);
}
