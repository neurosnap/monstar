const std = @import("std");

pub const BorderType = enum {
    none,
    single,
    double,
    rounded,
    heavy,

    pub fn parse(str: []const u8) ?BorderType {
        if (std.mem.eql(u8, str, "none")) return .none;
        if (std.mem.eql(u8, str, "single")) return .single;
        if (std.mem.eql(u8, str, "double")) return .double;
        if (std.mem.eql(u8, str, "rounded")) return .rounded;
        if (std.mem.eql(u8, str, "heavy")) return .heavy;
        return null;
    }
};

pub const Anchor = enum {
    center,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    cursor_relative,
    flex,

    pub fn parse(str: []const u8) ?Anchor {
        if (std.mem.eql(u8, str, "center")) return .center;
        if (std.mem.eql(u8, str, "top_left") or std.mem.eql(u8, str, "top-left")) return .top_left;
        if (std.mem.eql(u8, str, "top_right") or std.mem.eql(u8, str, "top-right")) return .top_right;
        if (std.mem.eql(u8, str, "bottom_left") or std.mem.eql(u8, str, "bottom-left")) return .bottom_left;
        if (std.mem.eql(u8, str, "bottom_right") or std.mem.eql(u8, str, "bottom-right")) return .bottom_right;
        if (std.mem.eql(u8, str, "cursor_relative") or std.mem.eql(u8, str, "cursor-relative") or std.mem.eql(u8, str, "cursor")) return .cursor_relative;
        if (std.mem.eql(u8, str, "flex")) return .flex;
        return null;
    }
};

pub const Direction = enum {
    column,
    row,
};

pub const Align = enum {
    left,
    center,
    right,
};

pub const Justify = enum {
    start,
    center,
    end,
    space_between,
    space_around,
};

pub const Backdrop = struct {
    dim: f32 = 0.5,
    blur: bool = false,
};

pub const LayerStyle = struct {
    border: BorderType = .none,
    border_fg: ?[]const u8 = null,
    border_bg: ?[]const u8 = null,
    title: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    fg: ?[]const u8 = null,
    shadow: bool = false,
    backdrop: ?Backdrop = null,
};

pub const LayerType = enum {
    root,
    modal,
    drawer,
    toast,
    popup,
    custom,

    pub fn parse(str: []const u8) LayerType {
        if (std.mem.eql(u8, str, "root")) return .root;
        if (std.mem.eql(u8, str, "modal")) return .modal;
        if (std.mem.eql(u8, str, "drawer")) return .drawer;
        if (std.mem.eql(u8, str, "toast")) return .toast;
        if (std.mem.eql(u8, str, "popup")) return .popup;
        return .custom;
    }
};

pub const WidgetType = enum {
    box,
    header,
    text,
    button,
    input,
    table,
    progress,
    list,
    custom,

    pub fn parse(str: []const u8) WidgetType {
        if (std.mem.eql(u8, str, "box")) return .box;
        if (std.mem.eql(u8, str, "header")) return .header;
        if (std.mem.eql(u8, str, "text")) return .text;
        if (std.mem.eql(u8, str, "button")) return .button;
        if (std.mem.eql(u8, str, "input")) return .input;
        if (std.mem.eql(u8, str, "table")) return .table;
        if (std.mem.eql(u8, str, "progress")) return .progress;
        if (std.mem.eql(u8, str, "list")) return .list;
        return .custom;
    }
};

pub const WidgetStyle = struct {
    bg: ?[]const u8 = null,
    fg: ?[]const u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const Widget = struct {
    type: WidgetType,
    id: ?[]const u8 = null,
    direction: Direction = .column,
    @"align": Align = .left,
    justify: Justify = .start,
    margin_top: u16 = 0,
    margin_bottom: u16 = 0,
    margin_left: u16 = 0,
    margin_right: u16 = 0,
    gap: u16 = 0,
    style: WidgetStyle = .{},

    // Text & Header
    text: ?[]const u8 = null,
    title: ?[]const u8 = null,

    // Button
    label: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    focused: bool = false,

    // Input
    placeholder: ?[]const u8 = null,
    value: ?[]const u8 = null,
    cursor_pos: u16 = 0,

    // Table
    headers: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    selected_index: ?usize = null,

    // Progress
    progress_val: f32 = 0.0,
    total: f32 = 1.0,

    // List
    items: []const []const u8 = &.{},

    // Children
    children: []Widget = &.{},
};

pub const Layer = struct {
    id: []const u8,
    type: LayerType = .modal,
    visible: bool = true,
    anchor: Anchor = .center,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    width: u16 = 40,
    height: u16 = 10,
    z_index: i32 = 0,
    direction: Direction = .column,
    style: LayerStyle = .{},
    children: []Widget = &.{},
};

pub const RpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?u64 = null,
    method: []const u8,
    params_json: ?[]const u8 = null,
};
