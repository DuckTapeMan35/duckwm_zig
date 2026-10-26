const std = @import("std");
const linux = std.os.linux;
const protocol = @import("protocol");
const core = @import("duckwm_client");
const keys = @import("keys.zig");
const value = @import("value.zig");
const arrange = @import("arrange.zig");

const Allocator = std.mem.Allocator;
const Command = protocol.Command;
const Value = protocol.Value;
const CallArgs = protocol.CallArgs;
const Callback = protocol.Callback;
pub const Reply = core.Reply;

pub const Error = core.Error || keys.KeyCombo.ParseError || error{
    /// duckwm answered with something of the wrong shape.
    Unexpected,
};

/// A callback: a function and the context it was registered with. args says
/// which kind of call it is (.key, .rule, .line...); arena lives for the call.
pub const Handler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, c: *Client, args: CallArgs, arena: Allocator) anyerror!Reply,

    /// A handler calling f(ctx, c, args, arena) with ctx's own type.
    pub fn of(
        comptime T: type,
        ctx: *T,
        comptime f: fn (ctx: *T, c: *Client, args: CallArgs, arena: Allocator) anyerror!Reply,
    ) Handler {
        const Wrap = struct {
            fn call(p: ?*anyopaque, c: *Client, args: CallArgs, arena: Allocator) anyerror!Reply {
                return f(@ptrCast(@alignCast(p.?)), c, args, arena);
            }
        };
        return .{ .ctx = ctx, .func = Wrap.call };
    }

    /// One without a context: f(c, args, arena).
    pub fn func_of(comptime f: fn (c: *Client, args: CallArgs, arena: Allocator) anyerror!Reply) Handler {
        const Wrap = struct {
            fn call(_: ?*anyopaque, c: *Client, args: CallArgs, arena: Allocator) anyerror!Reply {
                return f(c, args, arena);
            }
        };
        return .{ .ctx = null, .func = Wrap.call };
    }
};

pub const Platform = enum { x11, river };

pub const WorkspaceState = enum { focused, active, inactive };

pub const Workspace = struct { position: u32, state: WorkspaceState };

pub const Client = struct {
    core: core.Client,
    gpa: Allocator,
    /// What the core calls for each of our callbacks; freed in deinit.
    thunks: std.ArrayListUnmanaged(*Thunk) = .empty,
    /// One factory per arranger, by name: see factory().
    factories: std.StringHashMapUnmanaged(u64) = .empty,
    /// duckwm's pid, from the socket.
    peer_pid: ?i32,
    started: ?bool = null,

    pub fn connect(gpa: Allocator) Error!Client {
        return from_core(gpa, try core.Client.connect(gpa));
    }

    /// Connect at a given path, e.g. another user's `/run/user/<uid>/duckwm.sock`.
    pub fn connect_to(gpa: Allocator, path: []const u8) Error!Client {
        return from_core(gpa, try core.Client.connect_to(gpa, path));
    }

    pub fn from_core(gpa: Allocator, c: core.Client) Client {
        return .{ .core = c, .gpa = gpa, .peer_pid = peer_pid(c.fd) };
    }

    pub fn deinit(c: *Client) void {
        for (c.thunks.items) |t| c.gpa.destroy(t);
        c.thunks.deinit(c.gpa);
        var it = c.factories.keyIterator();
        while (it.next()) |k| c.gpa.free(k.*);
        c.factories.deinit(c.gpa);
        c.core.deinit();
        c.* = undefined;
    }

    // ---- requests ----
    /// Run the commands as one transaction; one result per command, in arena.
    pub fn run(c: *Client, arena: Allocator, cmds: []const Command) Error![]const Value {
        return c.core.run(arena, cmds);
    }

    pub fn run_one(c: *Client, arena: Allocator, cmd: Command) Error!Value {
        return c.core.run_one(arena, cmd);
    }

    /// After error.Rejected: what duckwm said.
    pub fn why(c: *const Client) []const u8 {
        return c.core.why;
    }

    /// Answer duckwm's calls until the connection closes (error.Closed).
    pub fn serve(c: *Client) Error!void {
        return c.core.serve();
    }

    /// For an event loop: when fd() is readable, answer the calls waiting.
    pub fn dispatch(c: *Client) Error!void {
        return c.core.dispatch();
    }

    pub fn fd(c: *const Client) i32 {
        return c.core.fd;
    }

    // ---- callbacks ----
    /// A raw callback, for any command that takes one.
    pub fn register(c: *Client, h: Handler) Allocator.Error!Callback {
        return c.register_thunk(.{ .handler = h });
    }

    pub fn unregister(c: *Client, cb: Callback) void {
        c.core.unregister(cb);
    }

    /// Bind a key ("super+shift+a") to h, called here on each press (args .key).
    pub fn bind(c: *Client, arena: Allocator, combo: []const u8, h: Handler) Error!void {
        const k = try keys.KeyCombo.parse(combo);
        const cb = try c.register(h);
        _ = try c.run_one(arena, .{ .bind = .{ .mods = k.mods.bits(), .key = k.key, .callback = cb } });
    }

    /// Bind a key to commands duckwm runs itself, so the key never waits on us.
    pub fn bind_commands(c: *Client, arena: Allocator, combo: []const u8, cmds: []const Command) Error!void {
        const k = try keys.KeyCombo.parse(combo);
        _ = try c.run_one(
            arena,
            .{ .bind_commands = .{
                .mods = k.mods.bits(),
                .key = k.key,
                .commands = cmds,
            } },
        );
    }

    /// A rule for every window: h gets args .rule, { event, id }, event one of
    /// "pre_map", "map", "unmap", "prop". Returns its id, for remove_rule.
    pub fn add_rule(c: *Client, arena: Allocator, h: Handler) Error!Value {
        return c.run_one(arena, .{ .add_rule = .{ .callback = try c.register(h) } });
    }

    /// Open the input bar; h gets args .line, { text }, on Enter.
    pub fn read_line(c: *Client, arena: Allocator, prompt: []const u8, initial: ?[]const u8, h: Handler) Error!void {
        _ = try c.run_one(
            arena,
            .{ .read_line = .{
                .prompt = prompt,
                .callback = try c.register(h),
                .initial = initial,
            } },
        );
    }

    // ---- arrangers ----
    /// The current workspace gets this arranger.
    pub fn set_arranger(c: *Client, arena: Allocator, a: arrange.Arranger) Error!void {
        _ = try c.run_one(arena, .{ .set_arranger = .{ .factory = try c.factory(a), .name = a.name } });
    }

    /// Node id (a workspace or group) gets this arranger.
    pub fn register_arranger(c: *Client, arena: Allocator, id: u32, a: arrange.Arranger) Error!void {
        _ = try c.run_one(
            arena,
            .{ .register_arranger = .{
                .id = id,
                .factory = try c.factory(a),
                .name = a.name,
            } },
        );
    }

    /// New workspaces, and those whose arranger went away, get a; the current one now.
    pub fn default_arranger(c: *Client, arena: Allocator, a: arrange.Arranger) Error!void {
        const f = try c.factory(a);
        _ = try c.run(arena, &.{
            .{ .set_default_arranger = .{ .factory = f, .name = a.name } },
            .{ .set_arranger = .{ .factory = f, .name = a.name } },
        });
    }

    /// One arranger callback and one factory per arranger: its state lives in
    /// duckwm, so every workspace shares the same function.
    fn factory(c: *Client, a: arrange.Arranger) Allocator.Error!Callback {
        if (c.factories.get(a.name)) |id| return .{ .id = id };
        const made = try c.register_thunk(.{ .arranger = a });
        const f = try c.register_thunk(.{ .factory = made.id });
        const name = try c.gpa.dupe(u8, a.name);
        errdefer c.gpa.free(name);
        try c.factories.put(c.gpa, name, f.id);
        return f;
    }

    fn register_thunk(c: *Client, t: Thunk) Allocator.Error!Callback {
        const p = try c.gpa.create(Thunk);
        errdefer c.gpa.destroy(p);
        p.* = t;
        try c.thunks.append(c.gpa, p);
        errdefer _ = c.thunks.pop();
        return c.core.register(.of(Thunk, p, Thunk.call));
    }

    // ---- which duckwm ----
    /// From duckwm's executable name (duckwm-river on Wayland).
    pub fn platform(c: *const Client) Platform {
        const pid = c.peer_pid orelse return .x11;
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/exe", .{pid}, 0) catch return .x11;
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const rc = linux.readlink(path, &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS) return .x11;
        const exe = std.fs.path.basename(buf[0..rc]);
        return if (std.mem.indexOf(u8, exe, "river") != null) .river else .x11;
    }

    /// True for the first connection to this duckwm process, from any client
    /// using this library, duckwm_rs or duckwm_py: for things to do once per session.
    pub fn startup(c: *Client) bool {
        if (c.started) |s| return s;
        c.started = blk: {
            const pid = c.peer_pid orelse break :blk false;
            const run_dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
            var buf: [std.posix.PATH_MAX]u8 = undefined;
            const mark = std.fmt.bufPrintSentinel(
                &buf,
                "{s}/duckwm-started-{d}",
                .{ run_dir, pid },
                0,
            ) catch break :blk false;
            const rc = linux.open(
                mark,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true },
                0o600,
            );
            if (linux.errno(rc) != .SUCCESS) break :blk false;
            _ = linux.close(@intCast(rc));
            break :blk true;
        };
        return c.started.?;
    }

    // ---- typed queries ----
    /// Every bound key combination, once each, in arena.
    pub fn get_keybinds(c: *Client, arena: Allocator) Error![]keys.KeyCombo {
        const items = value.list(try c.run_one(arena, .get_keybinds)) orelse return error.Unexpected;
        const out = try arena.alloc(keys.KeyCombo, items.len);
        for (out, items) |*o, b| {
            const mods = value.int(value.get(b, "mods")) orelse return error.Unexpected;
            const key = value.str(value.get(b, "key")) orelse return error.Unexpected;
            o.* = .{ .mods = .from_bits(std.math.cast(u32, mods) orelse return error.Unexpected), .key = key };
        }
        return out;
    }

    /// The workspaces at the current level, in order, in arena.
    pub fn get_workspace_states(c: *Client, arena: Allocator) Error![]Workspace {
        const items = value.list(try c.run_one(arena, .get_workspace_states)) orelse return error.Unexpected;
        const out = try arena.alloc(Workspace, items.len);
        for (out, items) |*o, w| {
            const pos = value.int(value.get(w, "position")) orelse return error.Unexpected;
            const state = std.meta.stringToEnum(
                WorkspaceState,
                value.str(value.get(w, "state")) orelse "",
            ) orelse return error.Unexpected;
            o.* = .{ .position = std.math.cast(u32, pos) orelse return error.Unexpected, .state = state };
        }
        return out;
    }
};

/// What the core client calls for one of ours.
const Thunk = union(enum) {
    handler: Handler,
    arranger: arrange.Arranger,
    /// A factory: names the arranger it made.
    factory: u64,

    fn call(t: *Thunk, zc: *core.Client, args: CallArgs, a: Allocator) anyerror!Reply {
        const c: *Client = @fieldParentPtr("core", zc);
        switch (t.*) {
            .handler => |h| return h.func(h.ctx, c, args, a),
            .arranger => |ar| {
                if (args != .arranger) return error.NotASnapshot;
                const s = try arrange.Snapshot.init(a, args.arranger);
                return ar.call(&s, a);
            },
            .factory => |made| return .{ .made = made },
        }
    }
};

/// The pid at the other end of a Unix socket.
fn peer_pid(sock: i32) ?i32 {
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(sock, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    if (linux.errno(rc) != .SUCCESS or cred.pid <= 0) return null;
    return cred.pid;
}

// ---- tests: against a fake duckwm on a socket pair ----

const testing = std.testing;
const wire = protocol.wire;

const Fake = struct {
    fd: i32,
    arena: std.heap.ArenaAllocator = .init(testing.allocator),

    fn frame(f: *Fake, body: []const u8) void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(body.len), .little);
        _ = linux.write(f.fd, &len, 4);
        _ = linux.write(f.fd, body.ptr, body.len);
    }

    fn respond(f: *Fake, results: []const Value) !void {
        f.frame(try wire.encode_server_response(f.arena.allocator(), results, null));
    }

    fn call(f: *Fake, callback: u64, args: CallArgs) !void {
        f.frame(try wire.encode_server_call(f.arena.allocator(), .{ .callback = callback, .args = args, .nested = true }));
    }

    fn recv(f: *Fake) !protocol.ClientMessage {
        const a = f.arena.allocator();
        var len: [4]u8 = undefined;
        _ = linux.read(f.fd, &len, 4);
        const body = try a.alloc(u8, std.mem.readInt(u32, &len, .little));
        var got: usize = 0;
        while (got < body.len) got += linux.read(f.fd, body[got..].ptr, body.len - got);
        return wire.decode_client_message(body, a);
    }
};

fn pair() !struct { Client, Fake } {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.SocketFailed;
    return .{ Client.from_core(testing.allocator, .from_fd(testing.allocator, fds[0])), .{ .fd = fds[1] } };
}

fn teardown(c: *Client, f: *Fake) void {
    c.deinit();
    _ = linux.close(f.fd);
    f.arena.deinit();
}

test "bind by name, and typed keybinds" {
    var c, var f = try pair();
    defer teardown(&c, &f);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Noop = struct {
        fn on(_: *Client, _: CallArgs, _: Allocator) anyerror!Reply {
            return .{};
        }
    };
    try f.respond(&.{.nil});
    try c.bind(a, "super+shift+u", .func_of(Noop.on));
    const sent = (try f.recv()).request.commands[0].bind;
    try testing.expectEqual(@as(u32, 65), sent.mods);
    try testing.expectEqualStrings("u", sent.key);
    try testing.expectError(error.UnknownModifier, c.bind(a, "hyper+u", .func_of(Noop.on)));

    const fields = [_]Value.Field{
        .{ .key = "mods", .value = .{ .integer = 64 } },
        .{ .key = "key", .value = .{ .str = "Return" } },
    };
    try f.respond(&.{.{ .list = &.{.{ .map = &fields }} }});
    const binds = try c.get_keybinds(a);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("super+Return", try std.fmt.bufPrint(&buf, "{f}", .{binds[0]}));
}

test "the arranger handshake" {
    var c, var f = try pair();
    defer teardown(&c, &f);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layouts = @import("layouts.zig");

    // set_arranger names a factory; asked again, the same one.
    try f.respond(&.{.nil});
    try c.set_arranger(a, layouts.tile);
    const set = (try f.recv()).request.commands[0].set_arranger;
    try testing.expectEqualStrings("tile", set.name.?);
    try f.respond(&.{.nil});
    try c.set_arranger(a, layouts.tile);
    try testing.expectEqual(set.factory.id, (try f.recv()).request.commands[0].set_arranger.factory.id);

    // duckwm calls the factory, which names the arranger; then the arranger.
    try f.call(set.factory.id, .factory);
    try c.dispatch();
    const arranger = (try f.recv()).ret.callback.?;
    const ws = [_]protocol.WindowInfo{
        .{ .id = 1, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
        .{ .id = 2, .geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
    };
    try f.call(arranger, .{ .arranger = .{
        .event = .map,
        .id = 2,
        .prev_id = 1,
        .work_area = .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .cursor_dx = 0,
        .cursor_dy = 0,
        .focused = 1,
        .windows = &ws,
        .layout = .{ .nodes = &.{} },
        .state = null,
    } });
    try c.dispatch();
    const ret = (try f.recv()).ret;
    try testing.expectEqual(@as(u32, 2), ret.commands[0].focus.id);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, (try value.ids(a, ret.state)).?);
}
