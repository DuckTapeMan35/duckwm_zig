const std = @import("std");
const protocol = @import("protocol");

const Allocator = std.mem.Allocator;

pub const Value = protocol.Value;

/// A map's field.
pub fn get(v: ?Value, key: []const u8) ?Value {
    const m = switch (v orelse return null) {
        .map => |m| m,
        else => return null,
    };
    for (m) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
    return null;
}

pub fn int(v: ?Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

/// An integer or a number, as f64.
pub fn num(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .number => |n| n,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

pub fn str(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .str => |s| s,
        else => null,
    };
}

pub fn boolean(v: ?Value) ?bool {
    return switch (v orelse return null) {
        .boolean => |b| b,
        else => null,
    };
}

/// A list's items (or several return values').
pub fn list(v: ?Value) ?[]const Value {
    return switch (v orelse return null) {
        .list, .multi => |l| l,
        else => null,
    };
}

pub fn is_nil(v: ?Value) bool {
    return v == null or v.? == .nil;
}

/// A list of ids, e.g. an arranger's window order kept in its state.
pub fn ids(a: Allocator, v: ?Value) Allocator.Error!?[]u32 {
    const items = list(v) orelse return null;
    const out = try a.alloc(u32, items.len);
    for (out, items) |*o, item| {
        const i = int(item) orelse return null;
        o.* = std.math.cast(u32, i) orelse return null;
    }
    return out;
}

/// The other way: a list of ids as a Value.
pub fn from_ids(a: Allocator, xs: []const u32) Allocator.Error!Value {
    const out = try a.alloc(Value, xs.len);
    for (out, xs) |*o, x| o.* = .{ .integer = x };
    return .{ .list = out };
}

const testing = std.testing;

test "readers chain through maps and lists" {
    const fields = [_]Value.Field{ .{ .key = "mods", .value = .{ .integer = 64 } }, .{ .key = "key", .value = .{ .str = "q" } } };
    const v: Value = .{ .list = &.{.{ .map = &fields }} };
    const first = list(v).?[0];
    try testing.expectEqual(@as(?i64, 64), int(get(first, "mods")));
    try testing.expectEqualStrings("q", str(get(first, "key")).?);
    try testing.expectEqual(@as(?i64, null), int(get(first, "nope")));
    try testing.expectEqual(@as(?f64, 64), num(get(first, "mods")));
    try testing.expect(is_nil(get(v, "x")));
}

test "ids round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try from_ids(a, &.{ 3, 1, 2 });
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, (try ids(a, v)).?);
    try testing.expectEqual(@as(?[]u32, null), try ids(a, .{ .str = "x" }));
}
