const std = @import("std");
const protocol = @import("protocol");

const Allocator = std.mem.Allocator;

pub const Axis = protocol.Axis;

/// protocol.Side: top, bottom, left, right.
pub const Side = protocol.Side;

/// How much to cut: a fraction of the length, or pixels.
pub const Amount = union(enum) {
    frac: f64,
    px: u32,

    fn of(amount: Amount, total: u32) u32 {
        const n: u32 = switch (amount) {
            .frac => |f| @intFromFloat(@max(0, @round(@as(f64, @floatFromInt(total)) * f))),
            .px => |px| px,
        };
        return @min(n, total);
    }
};

/// A rectangle: position, then size. The same fields as protocol.Rect.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn from(r: protocol.Rect) Rect {
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    }

    pub fn to(r: Rect) protocol.Rect {
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    }

    /// Take a piece off one side: the piece, and what's left.
    pub fn cut(r: Rect, side: Side, amount: Amount) struct { Rect, Rect } {
        const x, const y, const w, const h = .{ r.x, r.y, r.width, r.height };
        switch (side) {
            .left => {
                const p = amount.of(w);
                return .{
                    .{ .x = x, .y = y, .width = p, .height = h },
                    .{ .x = x + @as(i32, @intCast(p)), .y = y, .width = w - p, .height = h },
                };
            },
            .right => {
                const p = amount.of(w);
                return .{
                    .{ .x = x + @as(i32, @intCast(w - p)), .y = y, .width = p, .height = h },
                    .{ .x = x, .y = y, .width = w - p, .height = h },
                };
            },
            .top => {
                const p = amount.of(h);
                return .{
                    .{ .x = x, .y = y, .width = w, .height = p },
                    .{ .x = x, .y = y + @as(i32, @intCast(p)), .width = w, .height = h - p },
                };
            },
            .bottom => {
                const p = amount.of(h);
                return .{
                    .{ .x = x, .y = y + @as(i32, @intCast(h - p)), .width = w, .height = p },
                    .{ .x = x, .y = y, .width = w, .height = h - p },
                };
            },
        }
    }

    /// Side by side (h) or stacked (v), by ratios. The pieces cover the
    /// rectangle exactly: rounding goes to the edges between them.
    pub fn split(r: Rect, a: Allocator, axis: Axis, ratios: []const f64) Allocator.Error![]Rect {
        var total: f64 = 0;
        for (ratios) |x| total += x;
        const length: f64 = @floatFromInt(if (axis == .h) r.width else r.height);
        const out = try a.alloc(Rect, ratios.len);
        var acc: f64 = 0;
        var prev: u32 = 0;
        for (out, ratios) |*o, x| {
            acc += x;
            const end: u32 = @intFromFloat(@round(length * acc / total));
            o.* = switch (axis) {
                .h => .{ .x = r.x + @as(i32, @intCast(prev)), .y = r.y, .width = end - prev, .height = r.height },
                .v => .{ .x = r.x, .y = r.y + @as(i32, @intCast(prev)), .width = r.width, .height = end - prev },
            };
            prev = end;
        }
        return out;
    }

    /// n equal parts.
    pub fn split_n(r: Rect, a: Allocator, axis: Axis, n: usize) Allocator.Error![]Rect {
        const ones = try a.alloc(f64, n);
        defer a.free(ones);
        @memset(ones, 1);
        return r.split(a, axis, ones);
    }

    /// rows x cols cells, row by row.
    pub fn grid(r: Rect, a: Allocator, rows: usize, cols: usize) Allocator.Error![]Rect {
        const out = try a.alloc(Rect, rows * cols);
        const lines = try r.split_n(a, .v, rows);
        defer a.free(lines);
        for (lines, 0..) |line, i| {
            const cells = try line.split_n(a, .h, cols);
            defer a.free(cells);
            @memcpy(out[i * cols ..][0..cols], cells);
        }
        return out;
    }
};

const testing = std.testing;

test "split covers exactly" {
    const parts = try (Rect{ .width = 100, .height = 50 }).split_n(testing.allocator, .h, 3);
    defer testing.allocator.free(parts);
    var sum: u32 = 0;
    for (parts) |p| sum += p.width;
    try testing.expectEqual(@as(u32, 100), sum);
    try testing.expectEqual(Rect{ .width = 33, .height = 50 }, parts[0]);
    try testing.expectEqual(@as(i32, 100), parts[2].x + @as(i32, @intCast(parts[2].width)));
}

test "cut sides" {
    const r: Rect = .{ .x = 10, .y = 10, .width = 100, .height = 100 };
    const piece, const rest = r.cut(.left, .{ .frac = 0.25 });
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 25, .height = 100 }, piece);
    try testing.expectEqual(Rect{ .x = 35, .y = 10, .width = 75, .height = 100 }, rest);
    try testing.expectEqual(
        Rect{ .x = 10, .y = 80, .width = 100, .height = 30 },
        r.cut(.bottom, .{ .px = 30 })[0],
    );
    try testing.expectEqual(@as(u32, 0), r.cut(.top, .{ .px = 500 })[1].height);
}

test "grid row by row" {
    const g = try (Rect{ .width = 200, .height = 100 }).grid(testing.allocator, 2, 2);
    defer testing.allocator.free(g);
    try testing.expectEqual(Rect{ .x = 100, .y = 0, .width = 100, .height = 50 }, g[1]);
    try testing.expectEqual(Rect{ .x = 0, .y = 50, .width = 100, .height = 50 }, g[2]);
}
