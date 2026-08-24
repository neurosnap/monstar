# Open Terminal Compositing Protocol (OTCP) Specification

**Version:** 1.0.0-draft  
**Status:** Working Draft  
**Target Audience:** Terminal Emulator Developers, CLI Tool Authors, TUI Framework Maintainers  

---

## 1. Abstract & Motivation

The terminal emulator ecosystem has traditionally relied on a single in-band stream (`/dev/tty` / serial discipline) where text characters, styling attributes, and cursor movements share the same linear channel.

Attempting to render modern UI elements (e.g., floating modal dialogs, cursor-anchored autocomplete dropdowns, command palettes, ephemeral toasts) using in-band ANSI escape sequences leads to:
1. **Screen Corruption**: Drawing over character cells destroys underlying scrollback history and cell state.
2. **Alternate Screen Trap**: Full-screen TUIs are forced into the alternate screen buffer (`\x1b[?1049h`), disabling native trackpad scrolling and terminal search.
3. **Escapes Desynchronization**: High-throughput terminal streams desynchronize and glitch when mixed with cursor-positioning escapes.

The **Open Terminal Compositing Protocol (OTCP)** standardizes an **out-of-band, multi-surface 2D compositing protocol** between CLI applications and terminal emulators.

Borrowing the architectural rigor of display servers like **Wayland**, OTCP models the terminal emulator as a multi-surface display server that arbitrates declarative overlay surfaces above the base PTY stream.

---

## 2. Core Architectural Principles (First Principles)

```
┌────────────────────────────────────────────────────────────────────────┐
│  APPLICATIONS, SHELLS & CLIENTS                                        │
│  • Legacy CLI/TUIs (bash, zsh, vim, htop) ──> PTY Stream (/dev/pts/N)  │
│  • Modern Tools (fzf, monstar-ui, sidecars)──> OTCP IPC ($GTTY_SOCK)   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Multiplexed Streams & IPC
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  TERMINAL COMPOSITOR & DISPLAY SERVER                                  │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ WORKSPACE & SURFACE SCENE GRAPH                                  │  │
│  │                                                                  │  │
│  │  ┌─────────────────────────────┐  ┌────────────────────────────┐ │  │
│  │  │ Pane A: tc_surface (pty)    │  │ Pane B: tc_surface (pty)   │ │  │
│  │  │ • Isolated VT State Machine │  │ • Isolated VT State Machine│ │  │
│  │  │ • Encapsulated Dual-Buffers:│  │ • Independent Scrollback B │ │  │
│  │  │   - Primary + Scrollback A  │  │ • Clamped 2D Matrix        │ │  │
│  │  │   - Alternate (TUI grid)    │  │                            │ │  │
│  │  │ ┌─────────────────────────┐ │  │ ┌────────────────────────┐ │ │  │
│  │  │ │ Layer: Autocomplete     │ │  │ │ Layer: Status Toast    │ │ │  │
│  │  │ └─────────────────────────┘ │  │ └────────────────────────┘ │ │  │
│  │  └─────────────────────────────┘  └────────────────────────────┘ │  │
│  │                                                                  │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ Global Workspace Overlays (Z-Top: Modals, Command Palette)  │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────┬─────────────────────────────────┘  │
│                                   │                                    │
│                                   ▼                                    │
│                    2D Compositing & Blending Pass                      │
│              (Z-ordering, Backdrop Dim, Shadows, Layout)               │
│              • Native Font Rasterization (FreeType/HarfBuzz)           │
│              • Terminal Color Themes (Catppuccin, Nord, etc.)          │
│              • Fractional DPI & Coordinate Mapping                     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Pixel Blit (Direct Memory)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  FRAMEBUFFER / DISPLAY OUTPUT (Wayland / X11 / Metal / DirectX)        │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Deconstructing Legacy Primary vs. Alternate Screen: The Surface Model
In traditional terminal emulators, the binary switch between the "Primary Buffer" (with scrollback) and the "Alternate Screen Buffer" (`\x1b[?1049h` / `smcup`/`rmcup`) was an in-band hack created for single-wire serial terminals. It caused the **Alternate Screen Trap**:
- Native trackpad and mouse scrollback are disabled.
- Terminal search is broken or inspects the wrong buffer.
- Screen history cannot be multiplexed or split without escape desynchronization and ANSI corruption.

OTCP eliminates the global primary/alt screen toggle. Instead, **scrollback history and cell coordinate spaces are properties of individual, compositable surfaces**:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        tc_surface (type="pty")                         │
│                                                                        │
│  PTY I/O Stream (/dev/pts/N) ──> Raw ANSI / UTF-8 Bytes                │
│                                    │                                   │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Encapsulated VT Parser & State Machine                           │  │
│  │ • Local cursor (x, y) & styles    • Mouse tracking modes         │  │
│  │ • Palette / OSC colors            • Bracketed paste & DEC modes  │  │
│  └──────────────────────────────────┬───────────────────────────────┘  │
│                                     │ switches active buffer           │
│                    ┌────────────────┴────────────────┐                 │
│                    ▼                                 ▼                 │
│  ┌─────────────────────────────────┐ ┌───────────────────────────────┐ │
│  │ Primary Buffer (Stream)         │ │ Alternate Buffer (Grid)       │ │
│  │ • 2D Viewport (Cols × Rows)     │ │ • Fixed 2D Grid (Cols × Rows) │ │
│  │ • Dedicated Scrollback Ring     │ │ • Zero Scrollback             │ │
│  │   (e.g., 10,000 lines)          │ │ • For vim, htop, less         │ │
│  └────────────────┬────────────────┘ └───────────────┬───────────────┘ │
│                   │                                  │                 │
│                   └─────────────────┬────────────────┘                 │
│                                     ▼                                  │
│                       Active Cell Matrix (Cols × Rows)                 │
│                                     │                                  │
│                 (Direct compositor blit to layout rect)                │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Surface Archetypes
OTCP formalizes four distinct surface archetypes:
1. **`pty` (Legacy PTY Surface Sandbox - "XWayland for Terminals")**:
   - Encapsulates an isolated VT parser instance and slave PTY (`/dev/pts/N` or Windows ConPTY).
   - Manages internal dual buffers (Primary with infinite scrollback + Alternate screen for legacy TUIs) in complete isolation.
   - **Strict Spatial Clamping**: Coordinates are constrained to $[0..W-1, 0..H-1]$. Escapes like `\x1b[2J` or rogue cursor moves cannot corrupt adjacent panes or sibling surfaces.
   - **Zero Upward Escapes**: Emits no ANSI escapes back to the compositor—only clean dirty-cell rectangles.
2. **`stream` (Pure Text / Log Stream Surface)**:
   - Structured, append-only sequential text stream with dedicated infinite scrollback, search, and text selection.
3. **`grid` (Programmatic 2D Cell Matrix)**:
   - Direct 2D addressable cell canvas $(W \times H)$ for modern TUI engines that bypass ANSI escape serialization entirely.
4. **`scene` / `layer` (Retained Declarative UI Surface)**:
   - Retained-mode semantic widget tree (`tc_widget`) rendered directly by the compositor.

### 2.3 True Multiplexer Isolation
Because each `tc_surface` owns its own scrollback buffer, cursor state, and mode flags:
- Multiplexers (tiling window splits, tabs, sidebars) create $N$ distinct surfaces without interleaved escape parsing.
- Scrolling back 1,000 lines in Pane A has zero impact on Pane B running a real-time log feed or Pane C running `neovim` in an alternate buffer.
- Overlays and layers can attach globally to the workspace or scope locally to an individual surface.

### 2.4 Declarative AST over the Wire (No Client Pixel Buffers)
**Clients do NOT transmit raw ARGB pixel buffers.** 
Instead, clients send lightweight declarative scene descriptions (boxes, text, buttons, lists, inputs). 

**Rationale:**
- **Zero Heavy Dependencies**: CLI utilities and shell scripts do not need to link FreeType, HarfBuzz, or fontconfig, nor rasterize glyphs.
- **Native Resolution & Theming**: The terminal emulator renders all text and widgets using its own font configuration, DPI scaling, and color scheme.
- **SSH Bandwidth Efficiency**: Declarative payloads are hundreds of bytes rather than megabytes of pixel buffers.

### 2.5 Wayland-Inspired Asymmetric Request/Event Model
OTCP defines two distinct directions of asynchronous communication:
- **Requests (Client $\to$ Server)**: Asynchronous instructions to create objects, configure properties, update widgets, and commit transactions.
- **Events (Server $\to$ Client)**: Asynchronous notifications emitted by the terminal emulator when semantic actions occur (button clicks, form submission, input text edits, modal dismissal, terminal resize).

### 2.6 Optimistic Object Allocation & Atomic Transactions
- **Zero-Roundtrip Staging**: Clients allocate object IDs locally and immediately send configuration requests without waiting for server acknowledgments.
- **Atomic Commits (`commit`)**: Changes staged on a layer or widget tree do not render until the client sends a `commit` request, preventing visual tearing and partial updates.

### 2.7 Local 60 FPS Visual Feedback vs. Semantic Events
The terminal emulator handles low-latency visual interactivity locally:
- Text cursor blinking, keyboard focus cycling (<kbd>Tab</kbd>), list item highlight navigation (<kbd>↑</kbd>/<kbd>↓</kbd>), and hover states run at display refresh rate without roundtrips.
- The server emits events to the client only when semantic state changes occur (e.g., <kbd>Enter</kbd> pressed, input modified, <kbd>Escape</kbd> dismissed).

---

## 3. Protocol Definition Format: JSON Protocol Schema

Rather than using XML (which lacks native parser support in many modern toolchains including Zig's standard library), OTCP interfaces are formally specified using a standardized **JSON Protocol Schema** (inspired by Wayland XML and Language Server Protocol metamodels).

The canonical schema is maintained at [`protocol/term-compositor.schema.json`](file:///home/erock/dev/term/monstar/protocol/term-compositor.schema.json).

### 3.1 Schema Structure
The protocol specification JSON defines:
- **`interfaces`**: Top-level object interfaces (`tc_display`, `tc_compositor`, `tc_layer`, `tc_widget`).
- **`requests`**: Methods invoked by the client on a specific object.
- **`events`**: Notifications emitted by the server targeting a specific object.
- **`$defs`**: Shared data types, enums, style dictionaries, and accessibility attributes.

### 3.2 Protocol Code Generator (`tc-scanner`)
Like `wayland-scanner`, language-specific scanner tools (such as `tc-scanner` in Zig) parse the protocol schema and generate:
1. Type-safe message representations (enums, structs, unions).
2. Wire serialization and deserialization routines.
3. Server dispatch vtables and epoll socket scaffolding.
4. Client SDK bindings with high-level builders.

---

## 4. Transport, Discovery, & Remote SSH

### 4.1 Transport Framing
OTCP messages are transmitted over a stream socket using **newline-delimited JSON (`\n` / LF)** framing.

Each message is a single-line JSON object:

#### Request (Client $\to$ Server):
```json
{"object": "<object_id>", "request": "<request_name>", "args": { ... }}
```

#### Event (Server $\to$ Client):
```json
{"object": "<object_id>", "event": "<event_name>", "args": { ... }}
```

### 4.2 Discovery Environment Variable
When an OTCP-compliant terminal emulator spawns a child process or shell, it MUST export:
- **`GTTY_SOCK`** (Primary) or **`TERMINAL_COMPOSITOR_SOCK`**
- Unix/macOS: Path to Unix domain socket (e.g., `$XDG_RUNTIME_DIR/gtty_<pid>.sock` or `/tmp/gtty_<pid>.sock`)
- Windows: Named Pipe path (e.g., `\\.\pipe\gtty_<pid>`)

### 4.3 Security & Permissions
- Sockets MUST be created with restricted file permissions (`0700` / `0600`), owned by the user's UID/GID.

### 4.4 100% SSH Forwarding Compatibility (No FD Passing)
Because OTCP transmits pure stream messages and **does not require Unix file descriptor passing (`SCM_RIGHTS`)**, it works transparently across OpenSSH Unix socket forwarding:

```ssh_config
# ~/.ssh/config snippet for OTCP Socket Forwarding:
Host *
    RemoteForward /tmp/gtty_%u.sock %d/gtty_%p.sock
    StreamLocalBindUnlink yes
```

Remote CLI tools write standard JSON requests to the forwarded socket. The remote host requires no display server, graphics stack, or compositor daemon.

### 4.5 Graceful Degradation
CLI tools MUST check for the presence and accessibility of `$GTTY_SOCK`. If absent or unreachable, applications MUST degrade gracefully to standard TTY/ANSI prompts without failing.

---

## 5. Core Protocol Interfaces

Below is the formal specification of core OTCP interfaces:

```
┌────────────────────────────────────────────────────────┐
│                      tc_display                        │
│          (Connection singleton, sync, errors)          │
└───────────────────────────┬────────────────────────────┘
                            │ creates
                            ▼
┌────────────────────────────────────────────────────────┐
│                     tc_compositor                      │
│             (Factory for surfaces and layers)          │
└─────────────┬────────────────────────────┬─────────────┘
              │ creates                    │ creates
              ▼                            ▼
┌───────────────────────────┐┌───────────────────────────┐
│        tc_surface         ││         tc_layer          │
│(pty sandbox, stream, grid)││(Overlay: anchor, styling) │
└─────────────┬─────────────┘└─────────────┬─────────────┘
              │ scopes/anchors to          │ attaches root
              └────────────────────────────►
                                           ▼
                             ┌───────────────────────────┐
                             │         tc_widget         │
                             │(Retained UI scene nodes)  │
                             └───────────────────────────┘
```

---

### 5.1 `tc_display` (Core Singleton Interface)

The global connection endpoint representing the terminal display server, session properties, and capability negotiation.

#### Requests:
- **`hello`**: Initial connection handshake sent by the client.
  - `client_name` (`string`): Identifying name of the client (e.g. `"fzf"`, `"monstar-ui"`, `"git-tool"`).
  - `client_version` (`string`, optional): Client version string.
  - `requested_interfaces` (`object`, optional): Map of interface names to client-supported max versions.
- **`sync`**: Requests a roundtrip synchronization point.
  - `callback_id` (`string`): Client-allocated ID for the `tc_callback` object.
- **`get_capabilities`**: Queries supported emulator capabilities, advertised interfaces, and security permissions.
- **`property_get`**: Queries active terminal/window/theme properties or feature flags.
  - `keys` (`array` of `string`): List of property keys to query (e.g. `["window.title", "features.clipboard_read"]`).
- **`property_set`**: Mutates writable terminal/window/theme properties.
  - `values` (`object`): Key-value dictionary of properties to set.
- **`property_watch`**: Subscribes to real-time asynchronous change notifications for specified properties or features.
  - `keys` (`array` of `string`): Properties or feature flags to watch.
- **`clipboard_get`**: Reads system clipboard or primary selection.
  - `target` (`string`): `"clipboard"` | `"primary"`.
  - `mime` (`string`): Preferred MIME type (default `"text/plain"`).
- **`clipboard_set`**: Writes data to system clipboard or primary selection.
  - `target` (`string`): `"clipboard"` | `"primary"`.
  - `mime` (`string`): Data MIME type.
  - `content` (`string`): Content string.
- **`system_bell`**: Triggers a system/visual terminal bell.
- **`system_notify`**: Posts a native desktop notification.
  - `title` (`string`)
  - `body` (`string`)
  - `urgency` (`string`, optional): `"low"` | `"normal"` | `"critical"`.

#### Events:
- **`capabilities`**: Response to `hello` / `get_capabilities`, broadcasting emulator metadata, active interface versions, and enabled feature flags.
  - `protocol_version` (`integer`)
  - `emulator` (`string`): Emulator name and version (e.g. `"monstar 1.1.0"`).
  - `interfaces` (`object`): Supported interfaces and version numbers (e.g. `{"tc_compositor":1,"tc_surface":1,"tc_layer":1,"tc_widget":1}`).
  - `features` (`object`): Boolean/status flags for capabilities (e.g. `{"clipboard_read":true,"backdrop_blur":true}`).
- **`property_values`**: Response containing queried property values.
  - `values` (`object`): Key-value dictionary of resolved properties.
- **`property_changed`**: Asynchronous notification when a watched property or feature mutates.
  - `key` (`string`)
  - `value` (`any`)
- **`clipboard_data`**: Response containing requested clipboard data.
  - `target` (`string`)
  - `mime` (`string`)
  - `content` (`string`)
- **`error`**: Error notification on invalid requests or permission rejection.
  - `object_id` (`string`)
  - `code` (`integer`): Standardized error code (e.g. `403` for `PERMISSION_DENIED`, `404` for `UNKNOWN_PROPERTY`).
  - `name` (`string`): Error identifier symbol.
  - `message` (`string`): Human-readable error description.

---

### 5.2 `tc_compositor` (Surface & Layer Factory)

Factory interface for creating composited surfaces and overlay layers.

#### Requests:
- **`create_surface`**: Instantiates a new independent display surface (for multiplexer panes, standalone streams, or programmatic grids).
  - `surface_id` (`string`): Unique client-allocated surface identifier.
  - `type` (`string`): `"pty"` | `"stream"` | `"grid"`. Default: `"pty"`.
  - `cols` (`integer`, min 1, optional): Initial width in character cells.
  - `rows` (`integer`, min 1, optional): Initial height in character cells.
  - `scrollback_max_lines` (`integer`, optional): Max scrollback buffer capacity. Default: `10000` (set `0` to disable scrollback).
  - `title` (`string`, optional): Surface title or tab label.
- **`create_layer`**: Instantiates a new overlay layer.
  - `layer_id` (`string`): Unique client-allocated layer identifier.
  - `type` (`string`): `"modal"` | `"popup"` | `"drawer"` | `"toast"` | `"custom"`. Default: `"modal"`.
  - `parent_surface` (`string`, optional): Target `surface_id` to scope and clip this layer to. If omitted, layers anchor to the global workspace window.

---

### 5.3 `tc_surface` (Composable Surface Interface)

Represents an independent rendering surface (such as a sandboxed legacy PTY pane, a text stream, or a 2D grid canvas).

#### Requests:
- **`resize`**: Requests geometry resizing for this surface.
  - `cols` (`integer`, min 1)
  - `rows` (`integer`, min 1)
- **`set_title`**: Sets the surface or tab title.
  - `title` (`string`)
- **`clear_scrollback`**: Clears the scrollback history buffer for this surface without disturbing active cell contents.
- **`destroy`**: Destroys the surface, closes any associated child PTY file descriptors, and releases compositor resources.

#### Events:
- **`configure`**: Emitted when the surface viewport geometry or cell size changes.
  - `grid_cols` (`integer`)
  - `grid_rows` (`integer`)
  - `cell_width_px` (`integer`)
  - `cell_height_px` (`integer`)
- **`cursor_position`**: Emitted when the surface's active text cursor position moves (useful for synchronizing cursor-anchored overlays).
  - `x` (`integer`): 0-indexed column coordinate.
  - `y` (`integer`): 0-indexed row coordinate.
  - `visible` (`boolean`): Cursor visibility state.
  - `shape` (`string`): `"block"` | `"beam"` | `"underline"`.
- **`buffer_swapped`**: Emitted when a `pty` surface transitions between primary and alternate buffers.
  - `active_buffer` (`string`): `"primary"` | `"alternate"`.
- **`title_changed`**: Emitted when an in-band control sequence (`OSC 0/2`) changes the surface title.
  - `title` (`string`)

---

### 5.4 `tc_layer` (Overlay Surface Interface)

Represents an active or staging overlay layer.

#### Requests:
- **`set_anchor`**: Defines positioning strategy relative to the parent surface or global workspace layout.
  - `mode` (`string`): `"center"` | `"top_left"` | `"top_right"` | `"bottom_left"` | `"bottom_right"` | `"cursor_relative"` | `"stream_inline"` | `"flex"`.
  - `parent_surface` (`string`, optional): Scopes placement and clipping to a specific `tc_surface`. If omitted, defaults to the layer's creation target or workspace root.
  - `offset_x` (`integer`): Character cell offset (or pixel offset when flagged). Default: `0`.
  - `offset_y` (`integer`): Character cell offset (or pixel offset when flagged). Default: `0`.
- **`set_size`**: Specifies bounding box dimensions in character grid units.
  - `cols` (`integer`, min 1)
  - `rows` (`integer`, min 1)
- **`set_style`**: Configures decorative visual properties.
  - `border` (`string`): `"none"` | `"single"` | `"double"` | `"rounded"` | `"heavy"`.
  - `title` (`string`, optional): Header cutout title string.
  - `border_fg` (`string`, optional): Hex color (`"#89b4fa"`) or semantic token.
  - `bg` (`string`, optional): Background fill hex color (`"#1e1e2e"`) or semantic token.
  - `shadow` (`boolean`): Enables drop shadow rendering.
  - `backdrop_dim` (`number`, 0.0 - 1.0, optional): Screen luminance dimming factor.
- **`set_root`**: Attaches a `tc_widget` scene graph root to this layer.
  - `widget` (`object`): Root widget tree.
- **`set_visible`**: Toggles visibility.
  - `visible` (`boolean`)
- **`seal_to_stream`**: Freezes/flattens the layer's current visual state into static text/cells in the target surface's scrollback stream and releases the active layer.
  - `target_surface` (`string`, optional): Target `surface_id` stream.
  - `fallback_text` (`string`, optional): Plain text representation to append to scrollback if cell capture is unavailable.
- **`commit`**: **Atomically commits** all staged changes to the compositor scene graph.
- **`destroy`**: Destroys the layer and frees server-side compositor resources.

#### Events:
- **`dismiss`**: Emitted when the layer is dismissed by user interaction.
  - `reason` (`string`): `"escape_key"` | `"backdrop_click"`.
- **`configure`**: Emitted when the terminal viewport geometry or cell size changes.
  - `grid_cols` (`integer`)
  - `grid_rows` (`integer`)
  - `cell_width_px` (`integer`)
  - `cell_height_px` (`integer`)

---

### 5.5 `tc_widget` (Retained Declarative UI Node)

Represents a retained-mode declarative UI element in the layer's scene graph.

#### Common Widget Properties:
- **`id`** (`string`, optional): Unique element identifier for event dispatching.
- **`a11y`** (`object`, optional): Accessibility overrides (`name`, `description`, `role`, `live`, `hidden`).
- **`style`** (`object`, optional): Styling attributes (`fg`, `bg`, `bold`, `italic`, `dim`).

#### Widget Types & Configurations:
- **`box`**: Flexbox layout container (`direction`, `align`, `justify`, `gap`, `children`).
- **`text`**: Static formatted text block (`content`, `align`).
- **`button`**: Clickable and focusable action button (`label`, `variant`, `focused`).
- **`input`**: Interactive editable text field (`placeholder`, `value`, `cursor_pos`, `focused`).
- **`list`**: Selectable item list with keyboard navigation (`items`, `selected_index`).
- **`table`**: Multi-column tabular data grid (`headers`, `rows`, `selected_index`).
- **`progress`**: Deterministic or indeterminate progress bar (`value`).

#### Widget Events:
- **`click`**: Emitted when a button or clickable element is triggered (`widget_id`).
- **`change`**: Emitted on real-time text input edits (`widget_id`, `value`, `cursor_pos`).
- **`submit`**: Emitted on <kbd>Enter</kbd> or double-click selection (`widget_id`, `selected_index`, `value`).

---

## 6. Capability & Property Subsystem

The property and capability system replaces fragile in-band ANSI/OSC escapes (such as `OSC 10/11` color queries, `OSC 0/2` title setting, and `OSC 52` clipboard manipulation) with a structured, out-of-band negotiation and query/setter mechanism.

### 6.1 Connection Handshake & Capability Negotiation

When a client connects to `$GTTY_SOCK`, it initiates a handshake to discover active interfaces, supported versions, and security policies:

```
 CLIENT                                              TERMINAL COMPOSITOR
 ──────                                              ───────────────────
 [Request] tc_display.hello(client_name="fzf") ───>
                                                    (Evaluates client, config & permissions)
                                               <─── [Event] tc_display.capabilities({
                                                        "protocol_version": 1,
                                                        "emulator": "monstar 1.1.0",
                                                        "interfaces": { "tc_compositor": 1, "tc_layer": 1, "tc_widget": 1 },
                                                        "features": {
                                                          "window_title_mutation": true,
                                                          "theme_customization": true,
                                                          "clipboard_read": true,
                                                          "clipboard_write": true,
                                                          "system_notifications": true,
                                                          "accessibility_tree": true
                                                        }
                                                    })
```

### 6.2 Dynamic Feature Flags & Permissions

Feature availability can be inspected at connect time or queried dynamically via `property_get`:

| Feature Flag | Type | Description |
| :--- | :--- | :--- |
| `features.window_title_mutation` | `boolean` | Permission to change window title / subtitle |
| `features.theme_customization` | `boolean` | Permission to override theme colors |
| `features.clipboard_read` | `boolean` | Permission to read system clipboard / primary selection |
| `features.clipboard_write` | `boolean` | Permission to write to system clipboard |
| `features.system_notifications` | `boolean` | Desktop notification capability |
| `features.backdrop_blur` | `boolean` | GPU/software backdrop blur support |
| `features.accessibility_tree` | `boolean` | Native OS accessibility bridge (AT-SPI2 / NSAccessibility) active |

If a client attempts to use a disabled or unauthorized capability, the server emits an explicit error event without crashing:
```json
{"object":"tc_display","event":"error","args":{"code":403,"name":"PERMISSION_DENIED","message":"Clipboard reading is disabled by user policy"}}
```

### 6.3 Property Namespaces

| Namespace | Key | Type | Access | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`window`** | `window.title` | `string` | Read / Write | Main terminal window title |
| | `window.subtitle` | `string` | Read / Write | Tab or pane subtitle / status line |
| | `window.grid` | `object` | Read-only | `{ "cols": 120, "rows": 40 }` |
| | `window.cell_size` | `object` | Read-only | `{ "width_px": 10, "height_px": 20 }` |
| | `window.scale` | `number` | Read-only | Fractional DPI scale factor (e.g. `1.5`) |
| | `window.focused` | `boolean` | Read / Watch | Active window focus state |
| **`theme`** | `theme.name` | `string` | Read / Write | Active theme name (`"Catppuccin Mocha"`) |
| | `theme.mode` | `string` | Read / Watch | Active color mode (`"dark"` \| `"light"`) |
| | `theme.bg` | `string` | Read / Write | Default background color (`"#1e1e2e"`) |
| | `theme.fg` | `string` | Read / Write | Default foreground color (`"#cdd6f4"`) |
| | `theme.cursor` | `string` | Read / Write | Cursor color hex |
| | `theme.ansi` | `array` | Read / Write | 16 ANSI color hex strings |
| **`clipboard`**| `clipboard.text` | `string` | Read / Write | System clipboard text |
| | `clipboard.primary`| `string` | Read / Write | Primary selection (middle-click) |
| **`a11y`** | `a11y.screen_reader_active`| `boolean` | Read / Watch | Active screen reader / AT-SPI detected |
| | `a11y.high_contrast` | `boolean` | Read / Watch | User requested high-contrast rendering |
| | `a11y.reduced_motion` | `boolean` | Read / Watch | User requested disabling animations/fades |

### 6.4 Property Request & Event Wire Examples

#### A. Handshake (`hello` $\to$ `capabilities`):
```json
{"object":"tc_display","request":"hello","args":{"client_name":"git-branch-selector","client_version":"0.2.1"}}
```
**Compositor Response:**
```json
{"object":"tc_display","event":"capabilities","args":{"protocol_version":1,"emulator":"monstar 1.1.0","interfaces":{"tc_compositor":1,"tc_layer":1,"tc_widget":1},"features":{"clipboard_read":true,"clipboard_write":true,"window_title_mutation":true,"system_notifications":true,"accessibility_tree":true}}}
```

#### B. Querying Theme & Window State (`property_get`):
```json
{"object":"tc_display","request":"property_get","args":{"keys":["window.title","theme.mode","theme.ansi","a11y.screen_reader_active"]}}
```
**Compositor Response:**
```json
{"object":"tc_display","event":"property_values","args":{"values":{"window.title":"monstar — ~/dev","theme.mode":"dark","theme.ansi":["#45475a","#f38ba8","#a6e3a1","#f9e2af","#89b4fa","#f5c2e7","#94e2d5","#bac2de","#585b70","#f38ba8","#a6e3a1","#f9e2af","#89b4fa","#f5c2e7","#94e2d5","#a6adc8"],"a11y.screen_reader_active":true}}}
```

#### C. Mutating Window & Theme Properties (`property_set`):
```json
{"object":"tc_display","request":"property_set","args":{"values":{"window.title":"zig build test (running...)","theme.bg":"#11111b"}}}
```

#### D. Clipboard Operations (`clipboard_set` / `clipboard_get`):
```json
{"object":"tc_display","request":"clipboard_set","args":{"target":"clipboard","mime":"text/plain","content":"git commit -m 'feat: otcp'"}}
```
```json
{"object":"tc_display","request":"clipboard_get","args":{"target":"clipboard","mime":"text/plain"}}
```
**Compositor Response:**
```json
{"object":"tc_display","event":"clipboard_data","args":{"target":"clipboard","mime":"text/plain","content":"git commit -m 'feat: otcp'"}}
```

#### E. Subscribing to State Changes (`property_watch`):
```json
{"object":"tc_display","request":"property_watch","args":{"keys":["theme.mode","window.focused","a11y.high_contrast"]}}
```
**Compositor Emits Asynchronously on Change:**
```json
{"object":"tc_display","event":"property_changed","args":{"key":"theme.mode","value":"light"}}
```

---

## 7. Theming & Style Tokens

To harmonize application intent with user color schemes and accessibility preferences, OTCP supports a cascading styling model:

### 7.1 Semantic Theme Tokens
Color and style fields accept either explicit hex strings (`"#89b4fa"`) or standard **Semantic Tokens** resolved dynamically by the terminal against the active user palette:
- **Surfaces**: `theme.bg.base`, `theme.bg.surface`, `theme.bg.elevated`
- **Typography**: `theme.fg.primary`, `theme.fg.muted`
- **Borders**: `theme.border.default`, `theme.border.focused`
- **Accents**: `theme.accent.primary`, `theme.accent.danger`, `theme.accent.warning`, `theme.accent.success`
- **ANSI Palette**: `ansi.<name>` (e.g., `ansi.red`, `ansi.bright_cyan`)

### 7.2 Cascading Priority & User Customization
Visual attributes are resolved in a clear cascading priority:
1. **Compositor Base Defaults**: Built-in fallbacks (e.g. rounded borders, 50% backdrop dim).
2. **Application Semantic Tokens**: App requests `bg: "theme.bg.surface"`, `variant: "danger"`.
3. **Application Explicit Overrides**: App specifies concrete RGB hex for syntax/artwork.
4. **End-User Configuration**: User preferences in emulator config (e.g. `monstar.conf`) override defaults (custom border styles, dimming percentages, or high-contrast enforcement).

When the user switches terminal themes (e.g. Dark $\leftrightarrow$ Light mode), the compositor immediately redraws all token-backed layers in the new palette with zero client roundtrips.

---

## 8. Accessibility & Assistive Technology (a11y)

Traditional terminals render flat character grids where screen readers (Orca, VoiceOver, NVDA) are blind to floating UI, buttons, and popups. 

Because OTCP represents overlays as a **retained declarative widget scene graph**, the terminal emulator directly exposes this tree to native OS accessibility buses (**Linux AT-SPI2 / D-Bus**, **macOS NSAccessibility**, and **Windows UI Automation**).

### 8.1 Inferred Semantic Role Mapping
The terminal compositor automatically maps OTCP widgets to standard assistive technology roles without requiring client boilerplate:

| Widget / Layer Type | Inferred a11y Role | Screen Reader Behavior |
| :--- | :--- | :--- |
| `tc_layer(type="modal")` | `ROLE_DIALOG` | Focus shifts to dialog; announces title and modal context. |
| `tc_layer(type="toast")` | `ROLE_NOTIFICATION` | Announced as an ephemeral live region event. |
| `tc_widget(type="button")` | `ROLE_PUSH_BUTTON` | Spoken as interactive button with focus and variant state. |
| `tc_widget(type="list")` | `ROLE_LIST` / `ROLE_LIST_ITEM` | Spoken with item index and count (*"2 of 5"*). |
| `tc_widget(type="input")` | `ROLE_ENTRY` / `ROLE_TEXT` | Spoken with current text value and placeholder hint. |
| `tc_widget(type="progress")` | `ROLE_PROGRESS_BAR` | Spoken with numeric percentage. |

### 8.2 The `a11y` Schema Block
Widgets and layers can supply explicit accessibility overrides:

```json
{
  "type": "button",
  "id": "close_btn",
  "label": "×",
  "a11y": {
    "name": "Close dialog",
    "description": "Press Escape or Enter to cancel deployment",
    "role": "button"
  }
}
```

- **`name`** (`string`, optional): Spoken label overriding visual abbreviations (e.g. `"Close dialog"` for `"×"`).
- **`description`** (`string`, optional): Extended context or keyboard shortcut hints.
- **`role`** (`string`, optional): Explicit role override (`"dialog"`, `"alert"`, `"button"`, `"textbox"`, `"list"`, `"listitem"`, `"progressbar"`, `"status"`, `"generic"`).
- **`live`** (`string`, optional): `"polite"` | `"assertive"` | `"off"`. Used for dynamic search result counts or output feeds.
- **`hidden`** (`boolean`, optional): When `true`, hides purely decorative dividers or spacers from assistive tools.

### 8.3 High Contrast & Reduced Motion
- When `a11y.high_contrast` is active, the compositor automatically enforces minimum $7:1$ WCAG contrast ratios and thickens border outlines.
- When `a11y.reduced_motion` is active, the compositor skips modal entry/exit transitions and popup animations.

---

## 9. End-to-End Interaction Examples

### 9.1 Modal Confirmation Dialog

```
 CLIENT                                              TERMINAL COMPOSITOR
 ──────                                              ───────────────────
 [Request] tc_compositor.create_layer("confirm_dlg", "modal")
 [Request] tc_layer.set_anchor("confirm_dlg", "center")
 [Request] tc_layer.set_size("confirm_dlg", 46, 9)
 [Request] tc_layer.set_style("confirm_dlg", border="rounded", title=" Deploy ", backdrop_dim=0.55)
 [Request] tc_layer.set_root("confirm_dlg", root_box_widget)
 [Request] tc_layer.commit("confirm_dlg")
                                                  ───> (Renders centered modal with dim)
                                                       (Emits AT-SPI focus event -> Orca announces dialog)
                                                       (User presses Tab -> focuses Confirm)
                                                       (User presses Enter)
                                                  <─── [Event] tc_widget.click("confirm_dlg", "confirm_btn")
 [Request] tc_layer.destroy("confirm_dlg")
                                                  ───> (Overlays cleared, undamaged VT restored)
```

#### Wire Payloads:

**1. Client Staging & Commit:**
```json
{"object":"tc_compositor","request":"create_layer","args":{"layer_id":"confirm_dlg","type":"modal"}}
{"object":"confirm_dlg","request":"set_anchor","args":{"mode":"center"}}
{"object":"confirm_dlg","request":"set_size","args":{"cols":46,"rows":9}}
{"object":"confirm_dlg","request":"set_style","args":{"border":"rounded","title":" Deploy to Production ","backdrop_dim":0.55,"shadow":true}}
{"object":"confirm_dlg","request":"set_root","args":{"widget":{"type":"box","direction":"column","children":[{"type":"text","content":"Are you sure you want to deploy v2.4.0?"},{"type":"box","direction":"row","justify":"center","gap":2,"margin_top":2,"children":[{"type":"button","id":"cancel_btn","label":" Cancel "},{"type":"button","id":"confirm_btn","label":" Confirm Deploy ","variant":"danger","focused":true,"a11y":{"description":"Permanently deploy v2.4.0 to production clusters"}}]}]}}}
{"object":"confirm_dlg","request":"commit","args":{}}
```

**2. Compositor Event Dispatch:**
```json
{"object":"confirm_dlg","event":"click","args":{"widget_id":"confirm_btn"}}
```

**3. Cleanup:**
```json
{"object":"confirm_dlg","request":"destroy","args":{}}
```

---

### 9.2 Cursor-Anchored Autocomplete Dropdown

For inline shell suggestions following active prompt coordinates:

**Client Request:**
```json
{"object":"tc_compositor","request":"create_layer","args":{"layer_id":"ac_menu","type":"popup"}}
{"object":"ac_menu","request":"set_anchor","args":{"mode":"cursor_relative","offset_x":0,"offset_y":1}}
{"object":"ac_menu","request":"set_size","args":{"cols":32,"rows":6}}
{"object":"ac_menu","request":"set_style","args":{"border":"rounded","title":" Suggestions ","shadow":true}}
{"object":"ac_menu","request":"set_root","args":{"widget":{"type":"list","id":"suggestions","selected_index":0,"items":["git status","git commit -m \"...\"","git push origin main"],"a11y":{"name":"Command suggestions"}}}}
{"object":"ac_menu","request":"commit","args":{}}
```

**Compositor Event on Item Selection:**
```json
{"object":"ac_menu","event":"submit","args":{"widget_id":"suggestions","selected_index":1,"value":"git commit -m \"...\""}}
```

---

## 10. Reference Implementations

- **Protocol Reference Implementation**: Monstar [`src/compositor/`](file:///home/erock/dev/term/monstar/src/compositor/) (Zig)
- **High-Throughput PTY Isolation Invariant Suite**: [`src/compositor/Compositor.zig`](file:///home/erock/dev/term/monstar/src/compositor/Compositor.zig)
- **Interactive Python Validation Client**: [`scripts/demo_overlay.py`](file:///home/erock/dev/term/monstar/scripts/demo_overlay.py)
- **Command Palette Companion**: [`scripts/command_palette.py`](file:///home/erock/dev/term/monstar/scripts/command_palette.py)
