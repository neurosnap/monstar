# Open Terminal Compositing Protocol (OTCP) Specification

**Version:** 1.0.0-draft  
**Status:** Working Draft  
**Target Audience:** Terminal Emulator Developers, CLI Tool Authors, TUI Framework Maintainers  

---

## 1. Abstract & Motivation

The terminal emulator ecosystem has traditionally relied on a single in-band stream (`/dev/tty` / serial discipline) where text characters, styling attributes, and cursor movements share the same linear channel.

Attempting to render modern UI elements (e.g., floating modal dialogs, cursor-anchored autocomplete dropdowns, command palettes, notifications) using in-band ANSI escape sequences leads to:
1. **Screen Corruption**: Drawing over character cells destroys underlying scrollback history and cell state.
2. **Alternate Screen Trap**: Full-screen TUIs are forced into the alternate screen buffer (`\x1b[?1049h`), disabling native trackpad scrolling and terminal search.
3. **Escapes Desynchronization**: High-throughput terminal streams desynchronize and glitch when mixed with cursor-positioning escapes.

The **Open Terminal Compositing Protocol (OTCP)** standardizes an **out-of-band, multi-surface 2D compositing protocol** between CLI applications and terminal emulators.

---

## 2. Architectural Model

```
┌────────────────────────────────────────────────────────────────────────┐
│  CLI Applications & Shells (bash, zsh, fzf, git, python, sidecars)     │
│  • PTY Stream (/dev/pts/N)  ──> Regular stdout/stderr text stream      │
│  • OTCP IPC ($GTTY_SOCK)    ──> Declarative UI & Event dispatch        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ JSON-RPC 2.0 (Unix Domain Socket)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  TERMINAL COMPOSITOR & DISPLAY SERVER                                  │
│                                                                        │
│  ┌───────────────────────────┐  ┌───────────────────────────────────┐  │
│  │ Base Surface (Stream)     │  │ Overlay Surfaces (Overlays)       │  │
│  │ • Ghostty VT / Text Grid  │  │ • Modals, Popups, Dropdowns       │  │
│  │ • Infinite scrollback     │  │ • Retained widget scene graph     │  │
│  └─────────────┬─────────────┘  └─────────────────┬─────────────────┘  │
│                │                                  │                    │
│                └─────────────────┬────────────────┘                    │
│                                  ▼                                     │
│                     2D Compositing & Blending Pass                     │
│                  (Z-ordering, Backdrop Dim, Shadows)                   │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ Pixel Blit
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│  FRAMEBUFFER / DISPLAY OUTPUT (Wayland / X11 / Metal / DirectX)        │
└────────────────────────────────────────────────────────────────────────┘
```

### Invariants:
1. **PTY Stream Independence**: The underlying terminal character grid, scrollback buffer, and PTY I/O stream MUST remain 100% untouched and unmutated by overlay rendering.
2. **Damage Repair**: When an overlay layer is created, updated, or destroyed, the terminal emulator is responsible for re-rasterizing the underlying VT cells cleanly.
3. **Zero ANSI Injections**: No escape sequences are injected into stdout/stdin.

---

## 3. Transport & Discovery

### 3.1 Environment Variable
When an OTCP-compliant terminal emulator spawns a child process or shell, it MUST export the socket location in the environment:
- **`GTTY_SOCK`** (Primary) or **`TERMINAL_COMPOSITOR_SOCK`**
- Unix/macOS: Path to Unix domain socket (e.g., `/tmp/gtty_<pid>.sock` or `$XDG_RUNTIME_DIR/gtty_<pid>.sock`)
- Windows: Named Pipe path (e.g., `\\.\pipe\gtty_<pid>`)

### 3.2 Security & Permissions
- Sockets MUST be created with restricted file permissions (`0700` / `0600`), owned by the user's UID/GID.

---

## 4. Protocol Framing & RPC Conventions

OTCP uses standard **JSON-RPC 2.0** delimited by newline characters (`\n` / LF):
- Every request from client to terminal contains `"jsonrpc": "2.0"`, `"method"`, `"params"`, and an optional `"id"`.
- Responses from the terminal contain `"jsonrpc": "2.0"`, `"id"`, and either `"result"` or `"error"`.
- Notifications sent from the terminal to the client (events) contain `"jsonrpc": "2.0"`, `"method"`, and `"params"`.

---

## 5. Protocol Methods

### 5.1 Capability Negotiation: `compositor.get_capabilities`
Allows clients to inspect supported features.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "compositor.get_capabilities",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocol_version": "1.0",
    "emulator": "monstar",
    "features": {
      "anchors": ["center", "top_left", "top_right", "bottom_left", "bottom_right", "cursor_relative"],
      "backdrop_dim": true,
      "drop_shadows": true,
      "widgets": ["box", "text", "button", "list", "table", "input", "progress"]
    }
  }
}
```

---

### 5.2 Layer Rendering: `layer.render`
Declares or replaces the active overlay layer set.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
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

---

### 5.3 Cursor-Anchored Autocomplete Example
For inline completion menus following the active shell prompt cursor:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "layer.render",
  "params": {
    "layers": [
      {
        "id": "suggestions_popup",
        "type": "popup",
        "anchor": "cursor_relative",
        "offset_x": 0,
        "offset_y": 1,
        "width": 32,
        "height": 6,
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
            "id": "item_list",
            "selected_index": 0,
            "items": [
              "git status",
              "git commit -m \"...\"",
              "git push origin main"
            ]
          }
        ]
      }
    ]
  }
}
```

---

### 5.4 Clear Overlays: `layer.clear`

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "layer.clear",
  "params": {}
}
```

---

## 6. Event Notification Protocol (Client Callbacks)

When user interactions occur within active layers, the terminal emulator dispatches notifications to connected clients over the socket:

### 6.1 Button Click / Activation: `event.click`
```json
{
  "jsonrpc": "2.0",
  "method": "event.click",
  "params": {
    "layer_id": "confirm_dialog",
    "widget_id": "confirm"
  }
}
```

### 6.2 Selection / Submit: `event.submit`
```json
{
  "jsonrpc": "2.0",
  "method": "event.submit",
  "params": {
    "layer_id": "suggestions_popup",
    "widget_id": "item_list",
    "selected_index": 1,
    "value": "git commit -m \"...\""
  }
}
```

### 6.3 Layer Dismissal (Escape key or backdrop click): `event.dismiss`
```json
{
  "jsonrpc": "2.0",
  "method": "event.dismiss",
  "params": {
    "layer_id": "confirm_dialog"
  }
}
```

---

## 7. Schema Reference

### 7.1 Anchor Modes
| Anchor | Description |
| :--- | :--- |
| `center` | Centered horizontally and vertically in the terminal viewport. |
| `top_left` | Positioned at top-left corner with `(offset_x, offset_y)`. |
| `top_right` | Positioned at top-right corner with `(offset_x, offset_y)`. |
| `bottom_left` | Positioned at bottom-left corner with `(offset_x, offset_y)`. |
| `bottom_right` | Positioned at bottom-right corner with `(offset_x, offset_y)`. |
| `cursor_relative` | Anchored relative to the current active VT cursor coordinate. |

### 7.2 Widget Types
- `box`: Layout container with flexbox-like `direction` (`row` / `column`), `gap`, `align`, `justify`.
- `text`: Formatted static text string with `align` (`left`, `center`, `right`).
- `button`: Clickable / keyboard-focusable action item with `label`, `variant` (`default`, `primary`, `danger`), `focused`.
- `list`: Selectable vertical list with `items` array and `selected_index`.
- `table`: Tabular data grid with `headers` and 2D `rows`.
- `input`: Single-line editable text field with `placeholder` and `value`.
- `progress`: Deterministic or indeterminate progress bar with `value` (0.0 - 1.0).

---

## 8. Reference Implementations

- **Terminal Compositor Engine**: Monstar [`src/compositor/`](file:///home/erock/dev/term/monstar/src/compositor/) (Zig)
- **Validation Test Suite**: Monstar [`scripts/validate_pty_isolation.py`](file:///home/erock/dev/term/monstar/scripts/validate_pty_isolation.py) (Python)
- **Interactive Demo Client**: Monstar [`scripts/demo_overlay.py`](file:///home/erock/dev/term/monstar/scripts/demo_overlay.py) (Python)

---
