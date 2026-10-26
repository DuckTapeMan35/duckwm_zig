const std = @import("std");
const protocol = @import("protocol");
const core = @import("duckwm_client");
const geometry = @import("geometry.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;
const Rect = geometry.Rect;
const Axis = geometry.Axis;
const Ref = protocol.Ref;
const ConstraintSpec = protocol.ConstraintSpec;
const NodeSpec = protocol.NodeSpec;
const Value = protocol.Value;

pub const Reply = core.Reply;
pub const Event = protocol.ArrangerEvent;

/// What an arranger sees: the event, the workspace's tiled windows, and its
/// layout and state as duckwm last stored them.
pub const Snapshot = struct {
    raw: protocol.Snapshot,
    event: Event,
    /// The window the event is about.
    id: u32,
    /// What was focused before the event.
    prev_id: ?u32,
    focused: ?u32,
    work_area: Rect,
    /// The cursor relative to the focused window.
    cursor: [2]i32,
    state: ?Value,
    /// The tiled windows, in the order they appeared; not the one being unmapped.
    windows: []const u32,

    pub fn init(a: Allocator, raw: protocol.Snapshot) Allocator.Error!Snapshot {
        var ws: std.ArrayListUnmanaged(u32) = try .initCapacity(a, raw.windows.len);
        for (raw.windows) |w| {
            if (raw.event == .unmap and w.id == raw.id) continue;
            ws.appendAssumeCapacity(w.id);
        }
        return .{
            .raw = raw,
            .event = raw.event,
            .id = raw.id,
            .prev_id = raw.prev_id,
            .focused = raw.focused,
            .work_area = .from(raw.work_area),
            .cursor = .{ raw.cursor_dx, raw.cursor_dy },
            .state = raw.state,
            .windows = ws.items,
        };
    }

    /// The work area, relative to itself: what window constraints are measured in.
    pub fn area(s: *const Snapshot) Rect {
        return .{ .width = s.work_area.width, .height = s.work_area.height };
    }

    pub fn geometry_of(s: *const Snapshot, window: u32) ?Rect {
        for (s.raw.windows) |w| if (w.id == window) return .from(w.geometry);
        return null;
    }

    /// The split ratios keyed container k has now: resizes end up here.
    pub fn ratios_of(s: *const Snapshot, k: u32) ?[]const f64 {
        for (s.raw.layout.nodes) |n| {
            if (n.id != .key or n.id.key != k) continue;
            for (n.constraints orelse &.{}) |c| if (c == .split) return c.split.ratios;
        }
        return null;
    }
};

// ---- refs and nodes ----
/// A window (or any node) by id.
pub fn id(x: u32) Ref {
    return .{ .id = x };
}

/// A container, by key.
pub fn key(k: u32) Ref {
    return .{ .key = k };
}

pub fn node(r: Ref, constraints: []const ConstraintSpec) NodeSpec {
    return .{ .id = r, .constraints = constraints };
}

// ---- constraints ----
/// Position and size, relative to the work area.
pub fn fixed(r: Rect) [4]ConstraintSpec {
    return .{
        .{ .fixed_x = .{ .value = r.x } },
        .{ .fixed_y = .{ .value = r.y } },
        .{ .fixed_width = .{ .value = r.width } },
        .{ .fixed_height = .{ .value = r.height } },
    };
}

/// A node placed at a rectangle of the work area.
pub fn at(a: Allocator, r: Ref, rect: Rect) Allocator.Error!NodeSpec {
    return node(r, try a.dupe(ConstraintSpec, &fixed(rect)));
}

pub fn grid_cell(container: Ref, col: u32, row: u32, cols: u32, rows: u32) ConstraintSpec {
    return .{ .grid_cell = .{ .col = col, .row = row, .cols = cols, .rows = rows, .container = container } };
}

/// An exact rectangle inside container, in its own coordinates.
pub fn grid_cell_abs(container: Ref, r: Rect) ConstraintSpec {
    return .{ .grid_cell_abs = .{ .x = r.x, .y = r.y, .w = r.width, .h = r.height, .container = container } };
}

/// The whole of container.
pub fn fill(container: Ref) ConstraintSpec {
    return grid_cell(container, 0, 0, 1, 1);
}

/// Divide container among children, side by side (h) or stacked (v); equal
/// shares without ratios.
pub fn split(a: Allocator, container: Ref, axis: Axis, children: []const Ref, ratios: ?[]const f64) Allocator.Error!ConstraintSpec {
    const r = ratios orelse blk: {
        const eq = try a.alloc(f64, children.len);
        @memset(eq, 1 / @as(f64, @floatFromInt(@max(children.len, 1))));
        break :blk eq;
    };
    return .{ .split = .{ .container = container, .axis = axis, .ratios = r, .children = children } };
}

// ---- order and replies ----
/// Last time's window order, minus closed windows, plus new ones: a mapped
/// window goes after the one that was focused, any others at the end.
/// duckwm calls an arranger with pre_map before map, and the new window is
/// already in that snapshot: it's placed then, and map finds it in place.
pub fn track(a: Allocator, s: *const Snapshot, old: []const u32) Allocator.Error![]u32 {
    var out: std.ArrayListUnmanaged(u32) = try .initCapacity(a, s.windows.len);
    for (old) |w| {
        if (std.mem.indexOfScalar(u32, s.windows, w) != null) out.appendAssumeCapacity(w);
    }
    for (s.windows) |w| {
        if (std.mem.indexOfScalar(u32, out.items, w) != null) continue;
        const mapping = s.event == .pre_map or s.event == .map;
        const after: ?usize = if (mapping and w == s.id) blk: {
            const p = s.prev_id orelse break :blk null;
            break :blk std.mem.indexOfScalar(u32, out.items, p);
        } else null;
        out.insertAssumeCapacity(if (after) |i| i + 1 else out.items.len, w);
    }
    return out.items;
}

/// The whole layout and the state to keep (null leaves it alone); a newly
/// mapped window gets focus. For a tree of rows and columns, tree.reply.
pub fn reply(a: Allocator, s: *const Snapshot, nodes: []const NodeSpec, state: ?Value) Allocator.Error!Reply {
    const commands: []const protocol.Command = if (s.event == .map)
        try a.dupe(protocol.Command, &.{.{ .focus = .{ .id = s.id } }})
    else
        &.{};
    return .{ .commands = commands, .layout = .{ .nodes = nodes }, .state = state };
}

// ---- arrangers ----
/// A layout function and its name. Bind it to a key, or make it the default
/// (Client.set_arranger, default_arranger).
pub const Arranger = struct {
    name: []const u8,
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, s: *const Snapshot, a: Allocator) anyerror!Reply,

    /// An arranger without state of its own: f(s, arena).
    pub fn simple(name: []const u8, comptime f: fn (s: *const Snapshot, a: Allocator) anyerror!Reply) Arranger {
        const Wrap = struct {
            fn call(_: ?*anyopaque, s: *const Snapshot, a: Allocator) anyerror!Reply {
                return f(s, a);
            }
        };
        return .{ .name = name, .func = Wrap.call };
    }

    /// One calling f(ctx, s, arena) with ctx's own type.
    pub fn of(
        name: []const u8,
        comptime T: type,
        ctx: *T,
        comptime f: fn (ctx: *T, s: *const Snapshot, a: Allocator) anyerror!Reply,
    ) Arranger {
        const Wrap = struct {
            fn call(p: ?*anyopaque, s: *const Snapshot, a: Allocator) anyerror!Reply {
                return f(@ptrCast(@alignCast(p.?)), s, a);
            }
        };
        return .{ .name = name, .ctx = ctx, .func = Wrap.call };
    }

    pub fn call(ar: Arranger, s: *const Snapshot, a: Allocator) anyerror!Reply {
        return ar.func(ar.ctx, s, a);
    }
};

const testing = std.testing;

fn snap(a: Allocator, event: Event, x: u32, prev: ?u32, windows: []const u32) !Snapshot {
    const ws = try a.alloc(protocol.WindowInfo, windows.len);
    for (ws, windows) |*w, i| w.* = .{ .id = i, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    return Snapshot.init(a, .{
        .event = event,
        .id = x,
        .prev_id = prev,
        .work_area = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .cursor_dx = 0,
        .cursor_dy = 0,
        .focused = null,
        .windows = ws,
        .layout = .{ .nodes = &.{} },
        .state = null,
    });
}

test "track puts a new window after the focused one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try snap(a, .map, 9, 1, &.{ 1, 2, 9 });
    try testing.expectEqualSlices(u32, &.{ 1, 9, 2 }, try track(a, &s, &.{ 1, 2 }));
}

test "track drops closed windows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An unmapping window isn't in s.windows any more.
    const s = try snap(a, .unmap, 2, 2, &.{ 1, 2, 3 });
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, s.windows);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, try track(a, &s, &.{ 1, 2, 3 }));
}

test "reply focuses a mapped window" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try snap(a, .map, 9, null, &.{9});
    const r = try reply(a, &s, &.{try at(a, id(9), s.area())}, null);
    try testing.expectEqual(@as(u32, 9), r.commands[0].focus.id);
    const f = try snap(a, .focus, 9, null, &.{9});
    try testing.expectEqual(@as(usize, 0), (try reply(a, &f, &.{}, null)).commands.len);
}

test "value ids for state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, (try value.ids(a, try value.from_ids(a, &.{ 4, 5 }))).?);
}

test "track places a new window at pre_map, and map keeps it there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pre = try snap(a, .pre_map, 9, 1, &.{ 1, 2, 9 });
    const placed = try track(a, &pre, &.{ 1, 2 });
    try testing.expectEqualSlices(u32, &.{ 1, 9, 2 }, placed);
    const map = try snap(a, .map, 9, 1, &.{ 1, 2, 9 });
    try testing.expectEqualSlices(u32, &.{ 1, 9, 2 }, try track(a, &map, placed));
}
