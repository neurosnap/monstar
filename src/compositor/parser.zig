const std = @import("std");
const msg = @import("message.zig");
const Layer = msg.Layer;
const Widget = msg.Widget;
const WidgetType = msg.WidgetType;
const Anchor = msg.Anchor;
const BorderType = msg.BorderType;
const LayerType = msg.LayerType;
const Direction = msg.Direction;
const Align = msg.Align;
const Justify = msg.Justify;

pub fn parseLayerRender(allocator: std.mem.Allocator, root_val: std.json.Value) ![]const Layer {
    var layers: std.ArrayList(Layer) = .empty;

    const layers_val = switch (root_val) {
        .object => |obj| obj.get("layers") orelse return error.MissingLayersField,
        .array => root_val,
        else => return error.InvalidLayersType,
    };

    switch (layers_val) {
        .array => |arr| {
            for (arr.items) |item| {
                const layer = try parseSingleLayer(allocator, item);
                try layers.append(allocator, layer);
            }
        },
        else => return error.InvalidLayersType,
    }

    return layers.toOwnedSlice(allocator);
}

fn parseSingleLayer(allocator: std.mem.Allocator, val: std.json.Value) !Layer {
    const obj = switch (val) {
        .object => |o| o,
        else => return error.InvalidLayerObject,
    };

    const id_val = obj.get("id") orelse return error.MissingLayerId;
    const id_str = switch (id_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidLayerId,
    };

    var l_type: LayerType = .modal;
    if (obj.get("type")) |t_val| {
        if (t_val == .string) l_type = LayerType.parse(t_val.string);
    }

    var visible: bool = true;
    if (obj.get("visible")) |v_val| {
        if (v_val == .bool) visible = v_val.bool;
    }

    var anchor: Anchor = .center;
    if (obj.get("anchor")) |a_val| {
        if (a_val == .string) anchor = Anchor.parse(a_val.string) orelse .center;
    }

    var offset_x: i32 = 0;
    if (obj.get("offset_x")) |ox_val| {
        if (ox_val == .integer) offset_x = @intCast(ox_val.integer);
    }

    var offset_y: i32 = 0;
    if (obj.get("offset_y")) |oy_val| {
        if (oy_val == .integer) offset_y = @intCast(oy_val.integer);
    }

    var width: u16 = 40;
    if (obj.get("width")) |w_val| {
        if (w_val == .integer) width = @intCast(w_val.integer);
    }

    var height: u16 = 10;
    if (obj.get("height")) |h_val| {
        if (h_val == .integer) height = @intCast(h_val.integer);
    }

    var z_index: i32 = 0;
    if (obj.get("z_index")) |z_val| {
        if (z_val == .integer) z_index = @intCast(z_val.integer);
    }

    var direction: Direction = .column;
    if (obj.get("direction")) |d_val| {
        if (d_val == .string and std.mem.eql(u8, d_val.string, "row")) direction = .row;
    }

    var style: msg.LayerStyle = .{};
    if (obj.get("style")) |s_val| {
        if (s_val == .object) {
            if (s_val.object.get("border")) |b_val| {
                if (b_val == .string) style.border = BorderType.parse(b_val.string) orelse .none;
            }
            if (s_val.object.get("border_fg")) |bfg| {
                if (bfg == .string) style.border_fg = try allocator.dupe(u8, bfg.string);
            }
            if (s_val.object.get("border_bg")) |bbg| {
                if (bbg == .string) style.border_bg = try allocator.dupe(u8, bbg.string);
            }
            if (s_val.object.get("title")) |t| {
                if (t == .string) style.title = try allocator.dupe(u8, t.string);
            }
            if (s_val.object.get("bg")) |bg| {
                if (bg == .string) style.bg = try allocator.dupe(u8, bg.string);
            }
            if (s_val.object.get("fg")) |fg| {
                if (fg == .string) style.fg = try allocator.dupe(u8, fg.string);
            }
            if (s_val.object.get("shadow")) |sh| {
                if (sh == .bool) style.shadow = sh.bool;
            }
            if (s_val.object.get("backdrop")) |bd| {
                if (bd == .object) {
                    var dim: f32 = 0.5;
                    if (bd.object.get("dim")) |dim_val| {
                        if (dim_val == .float) dim = @floatCast(dim_val.float) else if (dim_val == .integer) dim = @floatFromInt(dim_val.integer);
                    }
                    style.backdrop = .{ .dim = dim };
                }
            }
        }
    }

    var children: []const Widget = &.{};
    if (obj.get("children")) |c_val| {
        if (c_val == .array) {
            var w_list: std.ArrayList(Widget) = .empty;
            for (c_val.array.items) |item| {
                const w = try parseWidget(allocator, item);
                try w_list.append(allocator, w);
            }
            children = try w_list.toOwnedSlice(allocator);
        }
    }

    return Layer{
        .id = id_str,
        .type = l_type,
        .visible = visible,
        .anchor = anchor,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .width = width,
        .height = height,
        .z_index = z_index,
        .direction = direction,
        .style = style,
        .children = children,
    };
}

fn parseWidget(allocator: std.mem.Allocator, val: std.json.Value) !Widget {
    const obj = switch (val) {
        .object => |o| o,
        else => return error.InvalidWidgetObject,
    };

    var w_type: WidgetType = .custom;
    if (obj.get("type")) |t_val| {
        if (t_val == .string) w_type = WidgetType.parse(t_val.string);
    }

    var id: ?[]const u8 = null;
    if (obj.get("id")) |id_val| {
        if (id_val == .string) id = try allocator.dupe(u8, id_val.string);
    }

    var text: ?[]const u8 = null;
    if (obj.get("text")) |txt_val| {
        if (txt_val == .string) text = try allocator.dupe(u8, txt_val.string);
    }

    var title: ?[]const u8 = null;
    if (obj.get("title")) |t_val| {
        if (t_val == .string) title = try allocator.dupe(u8, t_val.string);
    }

    var label: ?[]const u8 = null;
    if (obj.get("label")) |lbl_val| {
        if (lbl_val == .string) label = try allocator.dupe(u8, lbl_val.string);
    }

    var variant: ?[]const u8 = null;
    if (obj.get("variant")) |var_val| {
        if (var_val == .string) variant = try allocator.dupe(u8, var_val.string);
    }

    var focused: bool = false;
    if (obj.get("focused")) |f_val| {
        if (f_val == .bool) focused = f_val.bool;
    }

    var margin_top: u16 = 0;
    if (obj.get("margin_top")) |mt| {
        if (mt == .integer) margin_top = @intCast(mt.integer);
    }

    var gap: u16 = 0;
    if (obj.get("gap")) |g| {
        if (g == .integer) gap = @intCast(g.integer);
    }

    var align_val: Align = .left;
    if (obj.get("align")) |al| {
        if (al == .string) {
            if (std.mem.eql(u8, al.string, "center")) align_val = .center else if (std.mem.eql(u8, al.string, "right")) align_val = .right;
        }
    }

    var justify_val: Justify = .start;
    if (obj.get("justify")) |jf| {
        if (jf == .string) {
            if (std.mem.eql(u8, jf.string, "center")) justify_val = .center else if (std.mem.eql(u8, jf.string, "end")) justify_val = .end;
        }
    }

    var direction: Direction = .column;
    if (obj.get("direction")) |dir| {
        if (dir == .string and std.mem.eql(u8, dir.string, "row")) direction = .row;
    }

    var headers: []const []const u8 = &.{};
    if (obj.get("headers")) |h_val| {
        if (h_val == .array) {
            var h_list: std.ArrayList([]const u8) = .empty;
            for (h_val.array.items) |item| {
                if (item == .string) try h_list.append(allocator, try allocator.dupe(u8, item.string));
            }
            headers = try h_list.toOwnedSlice(allocator);
        }
    }

    var rows: []const []const []const u8 = &.{};
    if (obj.get("rows")) |r_val| {
        if (r_val == .array) {
            var r_list: std.ArrayList([]const []const u8) = .empty;
            for (r_val.array.items) |row_item| {
                if (row_item == .array) {
                    var cell_list: std.ArrayList([]const u8) = .empty;
                    for (row_item.array.items) |cell_item| {
                        if (cell_item == .string) try cell_list.append(allocator, try allocator.dupe(u8, cell_item.string));
                    }
                    try r_list.append(allocator, try cell_list.toOwnedSlice(allocator));
                }
            }
            rows = try r_list.toOwnedSlice(allocator);
        }
    }

    var items: []const []const u8 = &.{};
    if (obj.get("items")) |it_val| {
        if (it_val == .array) {
            var it_list: std.ArrayList([]const u8) = .empty;
            for (it_val.array.items) |item| {
                if (item == .string) try it_list.append(allocator, try allocator.dupe(u8, item.string));
            }
            items = try it_list.toOwnedSlice(allocator);
        }
    }

    var selected_index: ?usize = null;
    if (obj.get("selected_index")) |si| {
        if (si == .integer) selected_index = @intCast(si.integer);
    }

    var children: []const Widget = &.{};
    if (obj.get("children")) |c_val| {
        if (c_val == .array) {
            var ch_list: std.ArrayList(Widget) = .empty;
            for (c_val.array.items) |item| {
                const child = try parseWidget(allocator, item);
                try ch_list.append(allocator, child);
            }
            children = try ch_list.toOwnedSlice(allocator);
        }
    }

    return Widget{
        .type = w_type,
        .id = id,
        .direction = direction,
        .@"align" = align_val,
        .justify = justify_val,
        .margin_top = margin_top,
        .gap = gap,
        .text = text,
        .title = title,
        .label = label,
        .variant = variant,
        .focused = focused,
        .headers = headers,
        .rows = rows,
        .items = items,
        .selected_index = selected_index,
        .children = children,
    };
}
