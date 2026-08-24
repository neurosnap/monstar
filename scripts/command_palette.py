#!/usr/bin/env python3
"""
Interactive Command Palette for Monstar (OTCP Client)
Demonstrates:
- Real-time text input filtering (event.change)
- Arrow key navigation (Up/Down) & focus management
- Execution of selected actions on Enter (event.submit)
- Clean dismissal on Escape (event.dismiss)
"""

import os
import sys
import json
import socket
import subprocess
import glob

COMMANDS = [
    {"id": "ui_autocomplete", "title": "UI: Shell Autocomplete Daemon", "cmd": "./zig-out/bin/monstar ui autocomplete"},
    {"id": "ui_confirm", "title": "UI: Confirm Dialog", "cmd": "./zig-out/bin/monstar ui dialog confirm \"Deploy to production?\" --danger"},
    {"id": "ui_select", "title": "UI: Select Branch Dialog", "cmd": "./zig-out/bin/monstar ui dialog select \"Select Git Branch\" --items \"main,staging,develop,feature/otcp\""},
    {"id": "ui_input", "title": "UI: Input Dialog", "cmd": "./zig-out/bin/monstar ui dialog input \"Enter commit message:\" --placeholder \"feat: ...\""},
    {"id": "ui_inspect", "title": "UI: Inspect Base Screen", "cmd": "./zig-out/bin/monstar ui inspect"},
    {"id": "ui_clear", "title": "UI: Clear Overlays", "cmd": "./zig-out/bin/monstar ui clear"},
    {"id": "git_status", "title": "Git: Status", "cmd": "git status"},
    {"id": "git_log", "title": "Git: Log Graph", "cmd": "git log --oneline --graph --decorate -n 15"},
    {"id": "git_diff", "title": "Git: Diff", "cmd": "git diff"},
    {"id": "sys_top", "title": "System: Top Processes", "cmd": "top -b -n 1 | head -n 20"},
    {"id": "sys_disk", "title": "System: Disk Usage", "cmd": "df -h"},
    {"id": "sys_uname", "title": "System: Kernel & OS Info", "cmd": "uname -a"},
    {"id": "monstar_test", "title": "Monstar: Run Test Suite", "cmd": "zig build test --summary all"},
]

def find_socket():
    if "GTTY_SOCK" in os.environ:
        return os.environ["GTTY_SOCK"]
    socks = sorted(glob.glob("/tmp/gtty_*.sock"), key=os.path.getmtime, reverse=True)
    if socks:
        return socks[0]
    return None

def build_palette_layers(search_query="", selected_index=0):
    query = search_query.strip().lower()
    filtered = [
        cmd for cmd in COMMANDS
        if not query or query in cmd["title"].lower() or query in cmd["cmd"].lower()
    ]
    
    if not filtered:
        items = ["(No matching commands)"]
        selected_index = 0
    else:
        items = [f"{i+1}. {cmd['title']} ({cmd['cmd']})" for i, cmd in enumerate(filtered)]
        selected_index = max(0, min(selected_index, len(items) - 1))

    return {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "layer.render",
        "params": {
            "layers": [
                {
                    "id": "cmd_palette",
                    "type": "modal",
                    "anchor": "center",
                    "width": 64,
                    "height": 14,
                    "style": {
                        "border": "rounded",
                        "title": " Monstar Command Palette (Type to filter, \u2191\u2193 to select, Enter to run, Esc to close) ",
                        "border_fg": "#89b4fa",
                        "bg": "#1e1e2e",
                        "shadow": True,
                        "backdrop": {"dim": 0.65}
                    },
                    "children": [
                        {
                            "type": "input",
                            "id": "palette_input",
                            "placeholder": "Type command, action, or filter...",
                            "value": search_query,
                            "cursor_pos": len(search_query),
                            "focused": True
                        },
                        {
                            "type": "list",
                            "id": "palette_list",
                            "margin_top": 1,
                            "selected_index": selected_index,
                            "items": items
                        }
                    ]
                }
            ]
        }
    }, filtered

def main():
    sock_path = find_socket()
    if not sock_path:
        print("Error: Monstar socket not found. Is Monstar running?", file=sys.stderr)
        sys.exit(1)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    print(f"Connected to Monstar at {sock_path}")

    current_query = ""
    current_selected = 0

    # Initial render
    req, filtered = build_palette_layers(current_query, current_selected)
    s.sendall((json.dumps(req) + "\n").encode())

    buf = ""
    while True:
        data = s.recv(4096)
        if not data:
            break
        buf += data.decode("utf-8", errors="replace")
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            method = msg.get("method")
            params = msg.get("params", {})

            if method == "event.change":
                # Realtime live filtering on input change
                val = params.get("value", "")
                current_query = val
                current_selected = 0
                req, filtered = build_palette_layers(current_query, current_selected)
                s.sendall((json.dumps(req) + "\n").encode())

            elif method == "event.submit":
                # User pressed Enter
                selected_idx = params.get("selected_index", current_selected)
                # Clear overlay
                clear_req = {"jsonrpc": "2.0", "id": 2, "method": "layer.clear"}
                s.sendall((json.dumps(clear_req) + "\n").encode())
                
                # Determine command to run
                if filtered and 0 <= selected_idx < len(filtered):
                    cmd_to_run = filtered[selected_idx]["cmd"]
                    print(f"\n[Command Palette] Executing: {cmd_to_run}\n")
                    subprocess.run(cmd_to_run, shell=True)
                elif current_query.strip():
                    # Run raw query as shell command
                    print(f"\n[Command Palette] Executing custom command: {current_query}\n")
                    subprocess.run(current_query, shell=True)
                s.close()
                return

            elif method == "event.dismiss":
                # User hit Escape
                s.close()
                return

if __name__ == "__main__":
    main()
