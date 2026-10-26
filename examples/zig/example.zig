//! duckwm from Zig: list the key bindings, bind super+u to kill the focused
//! window, tile every workspace, and keep it all up across duckwm restarts.
//!
//!     zig build examples && ./zig-out/bin/example-zig

const std = @import("std");
const duckwm = @import("duckwm");

var presses: usize = 0;

fn on_super_u(c: *duckwm.Client, _: duckwm.CallArgs, arena: std.mem.Allocator) anyerror!duckwm.Reply {
    presses += 1;
    // Runs inside the transaction the key press started.
    const focused = duckwm.value.int(try c.run_one(arena, .get_focused)) orelse return .{};
    std.debug.print("press {d}: killing {d}\n", .{ presses, focused });
    return .{ .commands = try arena.dupe(duckwm.Command, &.{.kill_client}) };
}

fn setup(_: void, c: *duckwm.Client) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("{t}, startup: {}\n", .{ c.platform(), c.startup() });
    for (try c.get_keybinds(a)) |k| std.debug.print("  {f}\n", .{k});
    try c.bind(a, "super+u", .func_of(on_super_u));
    try c.default_arranger(a, duckwm.layouts.tile);
}

pub fn main() void {
    duckwm.forever(std.heap.c_allocator, {}, setup);
}
