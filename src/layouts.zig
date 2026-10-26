const std = @import("std");
const arrange = @import("arrange.zig");
const tree = @import("tree.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;
const Snapshot = arrange.Snapshot;
const Reply = arrange.Reply;

/// Columns of near-equal windows: two side by side, then as square as possible.
pub const fair: arrange.Arranger = .simple("fair", fair_fn);

fn fair_fn(s: *const Snapshot, a: Allocator) anyerror!Reply {
    const n = s.windows.len;
    const rows: usize = if (n <= 2) 1 else std.math.sqrt(n - 1) + 1; // ceil(sqrt(n))
    var columns: std.ArrayListUnmanaged(?tree.Tree) = .empty;
    var i: usize = 0;
    while (i < n) : (i += rows) {
        const chunk = s.windows[i..@min(n, i + rows)];
        try columns.append(a, try tree.col(a, try tree.windows(a, chunk), .{}));
    }
    return tree.reply(a, s, try tree.row(a, columns.items, .{}), null);
}

/// Master and stack: the first window on the left, the rest stacked on the right.
pub const tile: arrange.Arranger = .simple("tile", tile_fn);

fn tile_fn(s: *const Snapshot, a: Allocator) anyerror!Reply {
    const old = try value.ids(a, s.state) orelse &.{};
    const order = try arrange.track(a, s, old);
    const master: ?tree.Tree = if (order.len > 0) .{ .window = order[0] } else null;
    const stack = if (order.len > 0) order[1..] else order;
    const layout = try tree.row(
        a,
        &.{ master, try tree.col(a, try tree.windows(a, stack), .{}) },
        .{ .ratios = &.{ 0.55, 0.45 } },
    );
    return tree.reply(a, s, layout, try value.from_ids(a, order));
}

const testing = std.testing;
const protocol = @import("protocol");

test "fair and tile" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ws = [_]protocol.WindowInfo{
        .{ .id = 1, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
        .{ .id = 2, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
        .{ .id = 3, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
    };
    const s = try Snapshot.init(a, .{
        .event = .map,
        .id = 3,
        .prev_id = 1,
        .work_area = .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .cursor_dx = 0,
        .cursor_dy = 0,
        .focused = 1,
        .windows = &ws,
        .layout = .{ .nodes = &.{} },
        .state = try value.from_ids(a, &.{ 1, 2 }),
    });
    // tile: 3 goes after 1, the focused one; master 1, stack 3, 2.
    const t = try tile.call(&s, a);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 2 }, (try value.ids(a, t.state)).?);
    try testing.expectEqual(@as(u32, 3), t.commands[0].focus.id);
    const root = t.layout.?.nodes[0].constraints.?;
    try testing.expectEqualSlices(f64, &.{ 0.55, 0.45 }, root[root.len - 1].split.ratios);

    // fair: 3 windows, 2 per column: two columns.
    const f = try fair.call(&s, a);
    const top = f.layout.?.nodes[0].constraints.?;
    try testing.expectEqual(@as(usize, 2), top[top.len - 1].split.children.len);
}
