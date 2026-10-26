const std = @import("std");
const protocol = @import("protocol");
const arrange = @import("arrange.zig");
const geometry = @import("geometry.zig");

const Allocator = std.mem.Allocator;
const Snapshot = arrange.Snapshot;
const NodeSpec = protocol.NodeSpec;
const ConstraintSpec = protocol.ConstraintSpec;

/// A window, or a branch of them.
pub const Tree = union(enum) {
    window: u32,
    branch: *const Branch,
};

pub const Branch = struct {
    axis: geometry.Axis,
    children: []const Tree,
    ratios: ?[]const f64,
    key: ?u32,
};

pub const Options = struct {
    /// Shares of the container; ignored unless there's one per child.
    ratios: ?[]const f64 = null,
    /// A key of its own, instead of the depth-first one.
    key: ?u32 = null,
};

pub fn window(x: u32) ?Tree {
    return .{ .window = x };
}

/// Windows as leaves, for row and col: `tree.col(a, try tree.windows(a, s.windows), .{})`.
pub fn windows(a: Allocator, ids: []const u32) Allocator.Error![]const ?Tree {
    const out = try a.alloc(?Tree, ids.len);
    for (out, ids) |*o, x| o.* = .{ .window = x };
    return out;
}

/// Children side by side; null children are skipped. No children is null,
/// one child (without a key) is just that child.
pub fn row(a: Allocator, children: []const ?Tree, opts: Options) Allocator.Error!?Tree {
    return branch(a, .h, children, opts);
}

/// Children stacked top to bottom.
pub fn col(a: Allocator, children: []const ?Tree, opts: Options) Allocator.Error!?Tree {
    return branch(a, .v, children, opts);
}

fn branch(a: Allocator, axis: geometry.Axis, children: []const ?Tree, opts: Options) Allocator.Error!?Tree {
    var kids: std.ArrayListUnmanaged(Tree) = try .initCapacity(a, children.len);
    for (children) |c| if (c) |t| kids.appendAssumeCapacity(t);
    if (kids.items.len == 0) return null;
    if (kids.items.len == 1 and opts.key == null) return kids.items[0];
    const ratios = if (opts.ratios) |r| (if (r.len == kids.items.len) r else null) else null;
    const b = try a.create(Branch);
    b.* = .{ .axis = axis, .children = kids.items, .ratios = ratios, .key = opts.key };
    return .{ .branch = b };
}

fn branches(a: Allocator, t: Tree, out: *std.ArrayListUnmanaged(*const Branch)) Allocator.Error!void {
    if (t != .branch) return;
    try out.append(a, t.branch);
    for (t.branch.children) |c| try branches(a, c, out);
}

/// The tree as nodes: keyed containers holding splits; the root fills the work area.
pub fn compile(a: Allocator, s: *const Snapshot, t: ?Tree) Allocator.Error![]const NodeSpec {
    const root = t orelse return &.{};
    const area = s.area();
    if (root == .window) return a.dupe(NodeSpec, &.{try arrange.at(a, arrange.id(root.window), area)});

    // Keys: explicit ones as given, the rest depth-first from 0, skipping those.
    var all: std.ArrayListUnmanaged(*const Branch) = .empty;
    try branches(a, root, &all);
    const keys = try a.alloc(u32, all.items.len);
    var next: u32 = 0;
    for (all.items, keys) |b, *k| {
        k.* = b.key orelse blk: {
            while (taken(all.items, next)) next += 1;
            next += 1;
            break :blk next - 1;
        };
    }

    var nodes: std.ArrayListUnmanaged(NodeSpec) = .empty;
    for (all.items, keys, 0..) |b, k, i| {
        const stored = if (s.ratios_of(k)) |r| (if (r.len == b.children.len and all_positive(r)) r else null) else null;
        const kids = try a.alloc(protocol.Ref, b.children.len);
        for (kids, b.children) |*r, c| r.* = switch (c) {
            .branch => |cb| arrange.key(keys[std.mem.indexOfScalar(*const Branch, all.items, cb).?]),
            .window => |x| arrange.id(x),
        };
        var cons: std.ArrayListUnmanaged(ConstraintSpec) = .empty;
        if (i == 0) try cons.appendSlice(a, &arrange.fixed(area));
        try cons.append(a, try arrange.split(a, arrange.key(k), b.axis, kids, stored orelse b.ratios));
        try nodes.append(a, arrange.node(arrange.key(k), cons.items));
        for (b.children) |c| if (c == .window) try nodes.append(a, arrange.node(arrange.id(c.window), &.{}));
    }
    return nodes.items;
}

fn taken(all: []const *const Branch, k: u32) bool {
    for (all) |b| if (b.key == k) return true;
    return false;
}

fn all_positive(r: []const f64) bool {
    for (r) |x| if (!(x > 0)) return false;
    return true;
}

/// arrange.reply, with the layout given as a tree.
pub fn reply(a: Allocator, s: *const Snapshot, t: ?Tree, state: ?protocol.Value) Allocator.Error!arrange.Reply {
    return arrange.reply(a, s, try compile(a, s, t), state);
}

const testing = std.testing;

fn snapshot(a: Allocator, ids: []const u32, layout: []const NodeSpec) !Snapshot {
    const ws = try a.alloc(protocol.WindowInfo, ids.len);
    for (ws, ids) |*w, i| w.* = .{ .id = i, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    return Snapshot.init(a, .{
        .event = .focus,
        .id = 0,
        .prev_id = null,
        .work_area = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .cursor_dx = 0,
        .cursor_dy = 0,
        .focused = null,
        .windows = ws,
        .layout = .{ .nodes = layout },
        .state = null,
    });
}

fn split_ratios(nodes: []const NodeSpec) []const f64 {
    for (nodes[0].constraints.?) |c| if (c == .split) return c.split.ratios;
    unreachable;
}

test "one child is just the child" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?Tree, .{ .window = 3 }), try row(a, &.{window(3)}, .{}));
    try testing.expectEqual(@as(?Tree, null), try col(a, &.{}, .{}));
    // ...unless it has a key of its own.
    try testing.expect((try row(a, &.{window(3)}, .{ .key = 5 })).? == .branch);
}

test "keys depth-first, skipping explicit ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try snapshot(a, &.{ 1, 2, 3 }, &.{});
    const t = try row(a, &.{ window(1), try col(a, try windows(a, &.{ 2, 3 }), .{}) }, .{ .key = 1 });
    const nodes = try compile(a, &s, t);
    var keys: std.ArrayListUnmanaged(u32) = .empty;
    for (nodes) |n| if (n.id == .key) try keys.append(a, n.id.key);
    // The root keeps 1; the column gets the first free one.
    try testing.expectEqualSlices(u32, &.{ 1, 0 }, keys.items);
    var fills = false;
    for (nodes[0].constraints.?) |c| fills = fills or (c == .fixed_width and c.fixed_width.value == 800);
    try testing.expect(fills); // the root fills the work area
}

test "stored ratios win while the shape holds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = arrange.node(arrange.key(0), &.{try arrange.split(a, arrange.key(0), .h, &.{ arrange.id(1), arrange.id(2) }, &.{ 0.7, 0.3 })});
    const s = try snapshot(a, &.{ 1, 2 }, &.{stored});
    try testing.expectEqualSlices(
        f64,
        &.{ 0.7, 0.3 },
        split_ratios(try compile(a, &s, try row(
            a,
            try windows(a, &.{ 1, 2 }),
            .{},
        ))),
    );
    // A third window: the shape changed, back to equal shares.
    try testing.expectEqual(@as(usize, 3), split_ratios(try compile(a, &s, try row(a, try windows(a, &.{ 1, 2, 3 }), .{}))).len);
}
