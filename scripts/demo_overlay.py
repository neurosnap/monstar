#!/usr/bin/env python3
"""
Interactive demonstration client for Monstar's next-generation multi-surface compositor.
Communicates with $GTTY_SOCK over Unix domain socket using JSON-RPC 2.0.
"""

import os
import sys
import json
import time
import socket
import glob

def find_socket():
    sock_path = os.environ.get("GTTY_SOCK")
    if sock_path and os.path.exists(sock_path):
        return sock_path
    
    # Fallback to scanning /tmp/gtty_*.sock
    socks = glob.glob("/tmp/gtty_*.sock")
    if socks:
        return socks[-1]
    return None

def send_rpc(sock_path, msg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    payload = (json.dumps(msg) + "\n").encode("utf-8")
    s.sendall(payload)
    resp = s.recv(4096)
    s.close()
    return json.loads(resp.decode("utf-8")) if resp else None

def demo_modal(sock_path):
    print(">> Rendering Confirmation Modal with backdrop dimming...")
    req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "layer.render",
        "params": {
            "layers": [
                {
                    "id": "confirm_dialog",
                    "type": "modal",
                    "anchor": "center",
                    "width": 46,
                    "height": 9,
                    "style": {
                        "border": "rounded",
                        "title": " Deploy to Production ",
                        "border_fg": "#89b4fa",
                        "bg": "#1e1e2e",
                        "shadow": True,
                        "backdrop": {"dim": 0.55}
                    },
                    "children": [
                        {
                            "type": "text",
                            "text": "Are you sure you want to deploy v2.4.0 to prod-east-1?",
                            "align": "left"
                        },
                        {
                            "type": "box",
                            "direction": "row",
                            "justify": "center",
                            "gap": 2,
                            "margin_top": 2,
                            "children": [
                                {
                                    "type": "button",
                                    "id": "cancel",
                                    "label": " Cancel ",
                                    "focused": False
                                },
                                {
                                    "type": "button",
                                    "id": "confirm",
                                    "label": " Confirm Deploy ",
                                    "variant": "danger",
                                    "focused": True
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    }
    send_rpc(sock_path, req)

def demo_autocomplete(sock_path):
    print(">> Rendering Cursor-Anchored Autocomplete Dropdown...")
    req = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "layer.render",
        "params": {
            "layers": [
                {
                    "id": "autocomplete_popup",
                    "type": "popup",
                    "anchor": "cursor_relative",
                    "offset_x": 0,
                    "offset_y": 1,
                    "width": 32,
                    "height": 7,
                    "style": {
                        "border": "rounded",
                        "title": " Suggestions ",
                        "border_fg": "#a6e3a1",
                        "bg": "#181825",
                        "shadow": True
                    },
                    "children": [
                        {
                            "type": "list",
                            "id": "ac_list",
                            "selected_index": 1,
                            "items": [
                                "1. git status",
                                "2. git commit -m \"...\"",
                                "3. git push origin main",
                                "4. git rebase -i HEAD~3"
                            ]
                        }
                    ]
                }
            ]
        }
    }
    send_rpc(sock_path, req)

def clear_overlays(sock_path):
    print(">> Clearing all overlays...")
    req = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "layer.clear",
        "params": {}
    }
    send_rpc(sock_path, req)

def main():
    sock = find_socket()
    if not sock:
        print("Error: No active Monstar compositor socket found ($GTTY_SOCK).")
        print("Please launch Monstar first: ./zig-out/bin/monstar")
        sys.exit(1)
    
    print(f"Connected to compositor socket: {sock}")
    
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "modal":
            demo_modal(sock)
        elif cmd == "popup" or cmd == "autocomplete":
            demo_autocomplete(sock)
        elif cmd == "clear":
            clear_overlays(sock)
        else:
            print(f"Unknown command: {cmd}")
        return

    print("Running automated showcase (3s modal -> 3s autocomplete -> clear)...")
    demo_modal(sock)
    time.sleep(3)
    demo_autocomplete(sock)
    time.sleep(3)
    clear_overlays(sock)
    print("Showcase complete!")

if __name__ == "__main__":
    main()
