# Monstar Next-Generation Multi-Surface Compositor Architecture

**A First-Principles Reimagining of the Terminal Emulator as a Multi-Surface Display Server and 2D Compositor, powered by Wayland (`wl_shm`), Ghostty VT, and Out-of-Band JSON-RPC IPC.**

---

## 1. Executive Summary & Problem Statement

The modern terminal ecosystem is built on a 50-year-old architectural compromise: **the 1970s Teletype / serial line discipline (`/dev/tty`)**.

Every terminal application, shell, and multiplexer today is forced to compress rich visual states, cursor movements, styling, window titles, and input queries into a **single, linear, append-only ASCII/ANSI byte stream** sent over a virtual serial cable.

```
Legacy Terminal Architecture (In-Band Serialization Flaw):
┌──────────────┐     Flat Byte Stream (/dev/tty)     ┌───────────────────────┐
│ Child Shell  │ ──────────────────────────────────> │ Dumb Terminal Screen  │
│ (bash / zsh) │   "ls\r\n\x1b[31mText\x1b[0m"       │ (1 flat 2D grid)      │
└──────────────┘                                     └───────────────────────┘
       ▲                                                         │
       │                  ANSI Escape String Hackery             │
       └─────────────────────────────────────────────────────────┘
              (No surfaces, no z-index, screen corruption)
```

### The Inherent Dead Ends of Legacy Architecture:
1. **The Single-Grid In-Band Bottleneck**: Traditional terminals expose only **one flat grid of character cells**. There is no native concept of "the underlying shell stream" vs. "a floating autocomplete popup" vs. "a modal dialog". Drawing a floating box directly onto the primary screen overwrites underlying scrollback cells, causing screen corruption, flickering, and ghost artifacts.
2. **The Alternate Screen Trap**: To avoid screen corruption, full-screen TUIs (`tmux`, `zellij`, `vim`) enter the Alternate Screen Buffer (`\x1b[?1049h`). This wipes the canvas and **destroys native trackpad scrollback and history access**, trapping the user inside an emulated grid.
3. **The CLI Middleware Limit**: Running a compositor as a CLI wrapper over a host terminal requires serializing 2D layer interactions back down into ANSI cursor escapes (`\x1b7`/`\x1b8`, `\x1b[B`), which desynchronizes under high throughput.

---

## 2. The Solution: A Composited Wayland Terminal

To solve this at the root, **the terminal emulator itself acts as a Multi-Surface Display Server and Compositor**.

```
Monstar Composited Terminal Architecture:
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  CLI Applications & Scripts (Bash, Zsh, Git, Python, fzf, CLI tools)                    │
│  Uses standard TTY for shell stream + $GTTY_SOCK for out-of-band UI                     │
└────────────────────────────────────────────┬────────────────────────────────────────────┘
                                             │ Structured JSON-RPC 2.0 ($GTTY_SOCK)
                                             ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  MONSTAR COMPOSITOR & DISPLAY SERVER ENGINE (`src/compositor/`)                         │
│                                                                                         │
│  ┌──────────────────────────────┐  ┌────────────────────────┐  ┌─────────────────────┐  │
│  │ Surface 0: Text Stream       │  │ Surface 1: Popup       │  │ Surface 2: Modal    │  │
│  │ (Infinite Native Scrollback) │  │ (Floating Autocomplete)│  │ (Command Palette)   │  │
│  │ [Ghostty VT PageList]        │  │ [Widget Scene Graph]   │  │ [Dialog Surface]    │  │
│  └──────────────────────────────┘  └────────────────────────┘  └─────────────────────┘  │
│                                            │                                            │
│                                            ▼                                            │
│                              2D Mathematical Compositor                                 │
│                    (Z-ordering, Occlusion, Backdrop Dimming, Shadows)                   │
└────────────────────────────────────────────┬────────────────────────────────────────────┘
                                             │ Unified ARGB8888 Pixel Buffer
                                             ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  WAYLAND DISPLAY / WL_SHM FRAMEBUFFER PRESENTATION                                      │
│  • High-performance CPU software rasterizer in Zig                                     │
│  • Direct blitting into Wayland shared memory buffers (`wl_shm`)                        │
│  • 100% immune to screen corruption, 0% ANSI escape sequence pollution                  │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Key Architectural Pillars

### Pillar 1: First-Class Surfaces (Stream vs. Canvas)
- **Stream Surfaces (Primary Shell)**:
  - Infinite height, append-only, backed by `ghostty-vt`'s high-performance `PageList`.
  - Maintains complete, unbroken scrollback history in memory.
  - Full trackpad scrolling, URL hovering, and mouse selection without alternate screen mode.
- **Canvas / Overlay Surfaces (Popups & Modals)**:
  - Retain-mode declarative UI surfaces with explicit $(x, y, z)$ coordinates.
  - Anchored dynamically: `center`, `top_left`, `bottom_right`, or `cursor_relative` (following cursor coordinates).
  - Rendered **above** the base shell stream with optional backdrop luminance dimming and drop shadows without touching underlying terminal text.

### Pillar 2: Out-of-Band Structured JSON-RPC Protocol (JSP)
Communication between sidecars, tools, and the compositor occurs exclusively over `$GTTY_SOCK`:
- **Zero Stdin/Stdout Pollution**: UI commands and state queries never inject escape sequences into the child process's I/O pipes.
- **Declarative UI Description**: Applications describe modals, pickers, tables, and buttons using clean JSON schemas.
- **Event Dispatching & Input Arbitration**: Key events (such as `Escape` to dismiss) and pointer clicks are routed to the active modal before reaching the child PTY.

### Pillar 3: Fast CPU 2D Framebuffer Compositor
- **Instantaneous Startup**: Sub-millisecond initialization with zero GPU driver overhead.
- **Direct Memory Blitting**: Blits directly into Monstar's `wl_shm` ARGB8888 pixel buffers right before Wayland surface commits.

---

## 4. Implementation Layout in Monstar

The compositor is located in a modular directory [`src/compositor/`](file:///home/erock/dev/term/monstar/src/compositor/):

```
monstar/
├── PROPOSAL.md                           # This architecture & status document
├── scripts/
│   └── demo_overlay.py                   # Python test client for live overlay demos
└── src/
    ├── main.zig                          # Exports compositor module & builds child env
    ├── App.zig                           # Owns Compositor, socket poll loop, and blitting pass
    ├── Window.zig                        # Wayland surface, wl_shm buffer pool
    │
    └── compositor/
        ├── Compositor.zig                # Master facade unifying Scene, Server, and Rendering
        ├── message.zig                   # AST schemas (Layer, Widget, Anchor, Border, Backdrop)
        ├── parser.zig                    # Streaming JSON parser for layer.render / surface.render
        ├── scene.zig                     # Scene graph, z-ordering, hit-testing, anchor geometry
        ├── blend.zig                     # Backdrop luminance dimming and drop shadow calculations
        ├── rasterizer.zig                # ARGB8888 software rasterizer for rounded boxes & widgets
        └── server.zig                    # Non-blocking Unix domain socket server (/tmp/gtty_$PID.sock)
```

---

## 5. JSON Surface Protocol (JSP) Reference

### A. Render Layers / Modals (`layer.render` / `surface.render`)
```json
{
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
          "shadow": true,
          "backdrop": { "dim": 0.55 }
        },
        "children": [
          {
            "type": "text",
            "text": "Are you sure you want to deploy v2.4.0?",
            "align": "left"
          },
          {
            "type": "box",
            "direction": "row",
            "justify": "center",
            "gap": 2,
            "margin_top": 2,
            "children": [
              { "type": "button", "id": "cancel", "label": " Cancel ", "focused": false },
              { "type": "button", "id": "confirm", "label": " Confirm ", "variant": "danger", "focused": true }
            ]
          }
        ]
      }
    ]
  }
}
```

### B. Cursor-Anchored Autocomplete (`cursor_relative`)
```json
{
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
          "shadow": true
        },
        "children": [
          {
            "type": "list",
            "id": "ac_list",
            "selected_index": 1,
            "items": [
              "1. git status",
              "2. git commit -m \"...\"",
              "3. git push origin main"
            ]
          }
        ]
      }
    ]
  }
}
```

### C. Clear Overlays (`layer.clear` / `surface.destroy`)
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "layer.clear",
  "params": {}
}
```

---

## 6. Current Implementation State

| Component | Status | Details |
| :--- | :--- | :--- |
| **Compositor Engine** | **Completed** | Full scene graph, z-indexing, anchor geometry, and widget tree parser in [`src/compositor/`](file:///home/erock/dev/term/monstar/src/compositor/). |
| **2D Software Rasterizer** | **Completed** | ARGB8888 pixel blitting, rounded borders, backdrop dimming, drop shadows in [`rasterizer.zig`](file:///home/erock/dev/term/monstar/src/compositor/rasterizer.zig) & [`blend.zig`](file:///home/erock/dev/term/monstar/src/compositor/blend.zig). |
| **IPC Server** | **Completed** | Non-blocking Unix socket server at `/tmp/gtty_$PID.sock` with `GTTY_SOCK` exported to child shell in [`server.zig`](file:///home/erock/dev/term/monstar/src/compositor/server.zig). |
| **Event Loop Integration** | **Completed** | Polling socket fd inside `App.run` pollset in [`src/App.zig`](file:///home/erock/dev/term/monstar/src/App.zig). |
| **Wayland Frame Blit** | **Completed** | `comp.renderOverlays(...)` blitting into `wl_shm` pixel buffers right before `window.commitRender`. |
| **Input Interception** | **Completed** | Modal overlay key interception and `Escape` dismissal in `onKey`. |
| **Build & Tests** | **Passing** | Clean `zig build` and `zig build test` in Monstar. |

---

## 7. How to Run & Verify

1. **Launch Monstar** (ensuring `WAYLAND_DISPLAY` is provided if not in default environment):
   ```bash
   WAYLAND_DISPLAY=wayland-1 ./zig-out/bin/monstar
   ```

2. **Trigger Overlays via Demo Client**:
   ```bash
   # In another terminal or inside Monstar's shell:
   python3 scripts/demo_overlay.py modal
   python3 scripts/demo_overlay.py autocomplete
   python3 scripts/demo_overlay.py clear
   ```

---

## 8. Next Enhancements

1. **Interactive Widget Navigation**:
   - Route `Tab`/`Shift-Tab`/arrow keys to change `focused` button / `selected_index` in active lists and tables.
   - Return `{ "event": "widget.click", "id": "confirm" }` or `{ "event": "submit" }` notifications over the JSON-RPC socket.
2. **Smooth Animations**:
   - Add spring-physics / easing transitions for modal entry/exit and popup opacity fade-in.
3. **Client SDKs**:
   - Provide lightweight zero-dependency client bindings for Zig, Rust, Go, Python, and C to easily build surface-aware CLI tools and shell extensions.
