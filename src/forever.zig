const std = @import("std");
const linux = std.os.linux;
const core = @import("duckwm_client");
const Client = @import("client.zig").Client;
const Allocator = std.mem.Allocator;

/// Run setup(ctx, &c) on every connection, then serve until it closes.
///
/// Everything setup registers dies with the connection on duckwm's side, so
/// it's simply redone on the next one. A config that fails (an error, or
/// duckwm rejecting it) is retried with a growing delay instead of hammering duckwm.
pub fn forever(gpa: Allocator, ctx: anytype, comptime setup: fn (@TypeOf(ctx), *Client) anyerror!void) noreturn {
    const path = core.socket_path(gpa) catch @panic("out of memory");
    defer gpa.free(path);
    forever_at(gpa, path, ctx, setup);
}

/// forever, at a given socket path.
pub fn forever_at(gpa: Allocator, path: []const u8, ctx: anytype, comptime setup: fn (@TypeOf(ctx), *Client) anyerror!void) noreturn {
    var delay: u64 = 1;
    var waiting = false;
    while (true) {
        var c = Client.connect_to(gpa, path) catch {
            if (!waiting) std.debug.print("duckwm: waiting for duckwm\n", .{});
            waiting = true;
            sleep(1);
            continue;
        };
        defer c.deinit();
        waiting = false;
        std.debug.print("duckwm: connected\n", .{});
        if (setup(ctx, &c)) {
            delay = 1;
            c.serve() catch |err| if (err != error.Closed) std.debug.print("duckwm: {t}\n", .{err});
            std.debug.print("duckwm: disconnected\n", .{});
            continue;
        } else |err| switch (err) {
            error.Closed => {
                std.debug.print("duckwm: disconnected\n", .{});
                continue;
            },
            error.Rejected => std.debug.print("duckwm: duckwm rejected the config: {s}\n", .{c.why()}),
            else => std.debug.print("duckwm: config failed: {t}\n", .{err}),
        }
        // Broken config: back off until it's fixed (or duckwm restarts).
        sleep(delay);
        delay = @min(delay * 2, 30);
    }
}

fn sleep(seconds: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(seconds), .nsec = 0 };
    _ = linux.nanosleep(&ts, null);
}
