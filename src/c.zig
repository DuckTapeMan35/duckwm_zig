//! The C API (include/duckwm.h): the Zig library (src/duckwm.zig) behind C
//! functions.
//!
//! C hands in commands as duckwm_command values and gets results back as
//! duckwm_value; the types are the generated ones in c_types.zig. Converting
//! is generic: each protocol type is paired with its C type field by field,
//! by name, the way src/gen_c.zig laid the C type out:
//!   []const u8     x            a NUL-terminated string
//!   []const T      x, x_len     a pointer and a count
//!   ?scalar        has_x, x
//!   ?other         x            a pointer, NULL when absent
//!   union          kind, u.x    a list payload as u.x.items, u.x.len

const std = @import("std");
const protocol = @import("protocol");
const duckwm = @import("duckwm");
const ct = @import("c_types.zig");
const is_list = @import("upstream/gen_common.zig").is_list;
const Allocator = std.mem.Allocator;

const gpa = std.heap.c_allocator;

/// Something C handed in that isn't a valid command.
const Invalid = error{Invalid};

// ---- C to Zig ----
fn is_compound(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        else => false,
    };
}

fn Elem(comptime List: type) type {
    return @typeInfo(List).pointer.child;
}

/// The C value x as Z. Strings and lists are copied into a, so the result
/// outlives the C memory it came from.
fn from_c(comptime Z: type, a: Allocator, x: anytype) (Invalid || Allocator.Error)!Z {
    switch (@typeInfo(Z)) {
        .bool, .int, .float => return x,
        .@"enum" => return std.enums.fromInt(Z, @backingInt(x)) orelse error.Invalid,
        .pointer => {
            comptime std.debug.assert(Z == []const u8);
            const s = x orelse return error.Invalid;
            return try a.dupe(u8, std.mem.span(s));
        },
        .@"struct" => |s| {
            var z: Z = undefined;
            inline for (s.field_names, s.field_types) |f, F| @field(z, f) = try field_from_c(F, a, x, f);
            return z;
        },
        .@"union" => |u| {
            inline for (u.field_names, u.field_types) |f, F| {
                if (x.kind == @field(@TypeOf(x.kind), f)) {
                    if (F == void) return @unionInit(Z, f, {});
                    const p = @field(x.u, f);
                    if (comptime is_list(F)) return @unionInit(Z, f, try list_from_c(Elem(F), a, p.items, p.len));
                    return @unionInit(Z, f, try from_c(F, a, p));
                }
            }
            return error.Invalid; // a kind that isn't one
        },
        else => @compileError("no C mapping for " ++ @typeName(Z)),
    }
}

/// Field f of the C struct x, as F.
fn field_from_c(comptime F: type, a: Allocator, x: anytype, comptime f: []const u8) (Invalid || Allocator.Error)!F {
    switch (@typeInfo(F)) {
        .optional => |o| {
            const O = o.child;
            const v = @field(x, f);
            if (O == []const u8) return if (v != null) try from_c(O, a, v) else null;
            if (comptime is_list(O)) return if (v != null) try list_from_c(Elem(O), a, v, @field(x, f ++ "_len")) else null;
            if (comptime is_compound(O)) return if (v) |p| try from_c(O, a, p.*) else null;
            return if (@field(x, "has_" ++ f)) try from_c(O, a, v) else null;
        },
        .pointer => if (comptime is_list(F)) return list_from_c(Elem(F), a, @field(x, f), @field(x, f ++ "_len")),
        else => {},
    }
    return from_c(F, a, @field(x, f));
}

fn list_from_c(comptime E: type, a: Allocator, ptr: anytype, len: usize) (Invalid || Allocator.Error)![]const E {
    if (len == 0) return &.{};
    const p = ptr orelse return error.Invalid;
    const out = try a.alloc(E, len);
    for (out, p[0..len]) |*o, x| o.* = try from_c(E, a, x);
    return out;
}

// ---- Zig to C ----
/// The element type of a C `?[*]const E`.
fn CElem(comptime Many: type) type {
    return @typeInfo(@typeInfo(Many).optional.child).pointer.child;
}

/// The Zig value z as C's C, everything it points to allocated in a.
fn to_c(comptime C: type, a: Allocator, z: anytype) Allocator.Error!C {
    const Z = @TypeOf(z);
    switch (@typeInfo(Z)) {
        .bool, .int, .float => return z,
        .@"enum" => return @fromBackingInt(@intCast(@backingInt(z))),
        .pointer => {
            comptime std.debug.assert(Z == []const u8);
            return (try a.dupeSentinel(u8, z, 0)).ptr;
        },
        .@"struct" => |s| {
            var c = std.mem.zeroes(C);
            inline for (s.field_names) |f| try field_to_c(&c, a, @field(z, f), f);
            return c;
        },
        .@"union" => {
            var c = std.mem.zeroes(C);
            c.kind = @fromBackingInt(@intCast(@backingInt(std.meta.activeTag(z))));
            switch (z) {
                inline else => |p, tag| {
                    const f = @tagName(tag);
                    const P = @TypeOf(p);
                    if (P == void) {} else if (comptime is_list(P)) {
                        const W = @TypeOf(@field(c.u, f));
                        @field(c.u, f) = .{
                            .items = try list_to_c(CElem(@FieldType(W, "items")), a, p),
                            .len = p.len,
                        };
                    } else @field(c.u, f) = try to_c(@TypeOf(@field(c.u, f)), a, p);
                },
            }
            return c;
        },
        else => @compileError("no C mapping for " ++ @typeName(Z)),
    }
}

/// Field f of c, set from v.
fn field_to_c(c: anytype, a: Allocator, v: anytype, comptime f: []const u8) Allocator.Error!void {
    const C = @TypeOf(c.*);
    const F = @TypeOf(v);
    switch (@typeInfo(F)) {
        .optional => |o| {
            const O = o.child;
            if (O == []const u8) {
                @field(c, f) = if (v) |s| try to_c(@FieldType(C, f), a, s) else null;
            } else if (comptime is_list(O)) {
                const items = v orelse &.{};
                @field(c, f) = try list_to_c(CElem(@FieldType(C, f)), a, items);
                @field(c, f ++ "_len") = items.len;
            } else if (comptime is_compound(O)) {
                @field(c, f) = if (v) |x| blk: {
                    const p = try a.create(@typeInfo(@typeInfo(@FieldType(C, f)).optional.child).pointer.child);
                    p.* = try to_c(@TypeOf(p.*), a, x);
                    break :blk p;
                } else null;
            } else {
                @field(c, "has_" ++ f) = v != null;
                if (v) |x| @field(c, f) = try to_c(@FieldType(C, f), a, x);
            }
        },
        .pointer => if (comptime is_list(F)) {
            @field(c, f) = try list_to_c(CElem(@FieldType(C, f)), a, v);
            @field(c, f ++ "_len") = v.len;
        } else {
            @field(c, f) = try to_c(@FieldType(C, f), a, v);
        },
        else => @field(c, f) = try to_c(@FieldType(C, f), a, v),
    }
}

fn list_to_c(comptime CE: type, a: Allocator, items: anytype) Allocator.Error!?[*]const CE {
    const out = try a.alloc(CE, items.len);
    for (out, items) |*o, x| o.* = try to_c(CE, a, x);
    return out.ptr;
}

// ---- the API's own types (hand-written in the header) ----
const Status = enum(c_int) {
    ok = 0,
    closed = 1,
    rejected = 2,
    protocol = 3,
    connect_failed = 4,
    no_memory = 5,
    invalid = 6,
};

const Results = extern struct {
    values: ?[*]const ct.duckwm_value,
    len: usize,
    _owner: ?*std.heap.ArenaAllocator,
};

/// duckwm_reply: what a C callback hands back, built with duckwm_reply_*.
/// Each of those copies into the call's arena at once, so nothing C passes
/// has to outlive the call to it.
const Reply = struct {
    a: Allocator,
    commands: std.ArrayListUnmanaged(protocol.Command) = .empty,
    r: duckwm.Reply = .{},
    /// Something C passed couldn't be converted: the transaction fails.
    bad: ?[]const u8 = null,

    fn set(r: *Reply, x: (Invalid || Allocator.Error)!void) Status {
        x catch |err| {
            r.bad = switch (err) {
                error.Invalid => "the callback's reply holds an invalid command or value",
                error.OutOfMemory => "out of memory",
            };
            return if (err == error.Invalid) .invalid else .no_memory;
        };
        return .ok;
    }
};

const Handler = *const fn (
    userdata: ?*anyopaque,
    c: *Conn,
    args: *const ct.duckwm_call_args,
    reply: *Reply,
) callconv(.c) void;

/// duckwm_client: the Zig client, plus what C needs kept for it.
const Conn = struct {
    c: duckwm.Client,
    /// What duckwm_last_error returns; NUL-terminated.
    why: std.ArrayListUnmanaged(u8) = .empty,
    /// What each registered C handler was registered with.
    thunks: std.AutoHashMapUnmanaged(u64, *Thunk) = .empty,

    fn create(zc: duckwm.Client) ?*Conn {
        const conn = gpa.create(Conn) catch return null;
        conn.* = .{ .c = zc };
        conn.set_why("");
        return conn;
    }

    fn set_why(conn: *Conn, msg: []const u8) void {
        conn.why.clearRetainingCapacity();
        conn.why.appendSlice(gpa, msg) catch {};
        conn.why.append(gpa, 0) catch {};
    }

    /// The status for err, with its message kept for duckwm_last_error.
    fn fail(conn: *Conn, err: (duckwm.Error || Invalid)) Status {
        switch (err) {
            error.Rejected => conn.set_why(conn.c.why()),
            error.Invalid => conn.set_why("invalid command: a NULL string or list, or an unknown kind or enum value"),
            else => conn.set_why(@errorName(err)),
        }
        return switch (err) {
            error.Closed => .closed,
            error.Rejected => .rejected,
            error.Protocol => .protocol,
            error.SocketFailed, error.ConnectFailed, error.PathTooLong => .connect_failed,
            error.OutOfMemory => .no_memory,
            error.Invalid, error.MissingKey, error.UnknownModifier, error.Unexpected => .invalid,
        };
    }
};

/// A C handler as a Zig one: converts the call's arguments to C, and the
/// reply it fills in back.
const Thunk = struct {
    h: Handler,
    userdata: ?*anyopaque,

    fn call(t: *Thunk, zc: *duckwm.Client, args: protocol.CallArgs, a: Allocator) anyerror!duckwm.Reply {
        const conn: *Conn = @fieldParentPtr("c", zc);
        const cargs = try to_c(ct.duckwm_call_args, a, args);
        var r: Reply = .{ .a = a };
        t.h(t.userdata, conn, &cargs, &r);
        if (r.bad) |why| return .{ .err = why };
        r.r.commands = r.commands.items;
        return r.r;
    }
};

// ---- replying, from inside a callback ----
export fn duckwm_reply_commands(r: *Reply, cmds: ?[*]const ct.duckwm_command, n: usize) Status {
    return r.set(blk: {
        const more = list_from_c(protocol.Command, r.a, cmds, n) catch |err| break :blk err;
        break :blk r.commands.appendSlice(r.a, more);
    });
}

export fn duckwm_reply_command(r: *Reply, cmd: ct.duckwm_command) Status {
    return duckwm_reply_commands(r, @ptrCast(&cmd), 1);
}

export fn duckwm_reply_layout(r: *Reply, layout: *const ct.duckwm_layout_spec) Status {
    return r.set(if (from_c(protocol.LayoutSpec, r.a, layout.*)) |l| {
        r.r.layout = l;
    } else |err| err);
}

export fn duckwm_reply_state(r: *Reply, state: *const ct.duckwm_value) Status {
    return r.set(if (from_c(protocol.Value, r.a, state.*)) |v| {
        r.r.state = v;
    } else |err| err);
}

export fn duckwm_reply_made(r: *Reply, id: u64) void {
    r.r.made = id;
}

export fn duckwm_reply_error(r: *Reply, msg: [*:0]const u8) Status {
    return r.set(if (r.a.dupe(u8, std.mem.span(msg))) |m| {
        r.r.err = m;
    } else |err| err);
}

// ---- the functions ----
export fn duckwm_connect() ?*Conn {
    return Conn.create(duckwm.Client.connect(gpa) catch return null);
}

export fn duckwm_connect_to(path: [*:0]const u8) ?*Conn {
    return Conn.create(duckwm.Client.connect_to(gpa, std.mem.span(path)) catch return null);
}

export fn duckwm_close(conn: ?*Conn) void {
    const c = conn orelse return;
    var it = c.thunks.valueIterator();
    while (it.next()) |t| gpa.destroy(t.*);
    c.thunks.deinit(gpa);
    c.why.deinit(gpa);
    c.c.deinit();
    gpa.destroy(c);
}

export fn duckwm_last_error(conn: *const Conn) [*:0]const u8 {
    return @ptrCast(conn.why.items.ptr);
}

export fn duckwm_fd(conn: *const Conn) c_int {
    return conn.c.fd();
}

export fn duckwm_run(conn: *Conn, cmds: ?[*]const ct.duckwm_command, n: usize, out: ?*Results) Status {
    if (out) |o| o.* = .{ .values = null, .len = 0, ._owner = null };
    const arena = gpa.create(std.heap.ArenaAllocator) catch return conn.fail(error.OutOfMemory);
    arena.* = .init(gpa);
    var keep = false;
    defer if (!keep) {
        arena.deinit();
        gpa.destroy(arena);
    };
    const a = arena.allocator();

    const zcmds = list_from_c(protocol.Command, a, cmds, n) catch |err| return conn.fail(err);
    const results = conn.c.run(a, zcmds) catch |err| return conn.fail(err);
    if (out) |o| {
        const values = list_to_c(ct.duckwm_value, a, results) catch |err| return conn.fail(err);
        o.* = .{ .values = values, .len = results.len, ._owner = arena };
        keep = true;
    }
    return .ok;
}

export fn duckwm_results_free(r: ?*Results) void {
    const res = r orelse return;
    if (res._owner) |arena| {
        arena.deinit();
        gpa.destroy(arena);
    }
    res.* = .{ .values = null, .len = 0, ._owner = null };
}

export fn duckwm_register(conn: *Conn, h: Handler, userdata: ?*anyopaque) u64 {
    const t = gpa.create(Thunk) catch return 0;
    t.* = .{ .h = h, .userdata = userdata };
    const cb = conn.c.register(.of(Thunk, t, Thunk.call)) catch {
        gpa.destroy(t);
        return 0;
    };
    conn.thunks.put(gpa, cb.id, t) catch {
        conn.c.unregister(cb);
        gpa.destroy(t);
        return 0;
    };
    return cb.id;
}

export fn duckwm_unregister(conn: *Conn, id: u64) void {
    conn.c.unregister(.{ .id = id });
    if (conn.thunks.fetchRemove(id)) |kv| gpa.destroy(kv.value);
}

export fn duckwm_serve(conn: *Conn) Status {
    conn.c.serve() catch |err| return conn.fail(err);
    unreachable; // serve only returns with an error
}

export fn duckwm_dispatch(conn: *Conn) Status {
    conn.c.dispatch() catch |err| return conn.fail(err);
    return .ok;
}

// ---- keys ----
/// The modifier bits and keysym of "super+shift+q"; key points into combo.
export fn duckwm_parse_combo(combo: [*:0]const u8, mods: ?*u32, key: ?*?[*:0]const u8) bool {
    const k = duckwm.KeyCombo.parse(std.mem.span(combo)) catch return false;
    if (mods) |m| m.* = k.mods.bits();
    if (key) |p| p.* = @ptrCast(k.key.ptr); // the tail of combo: NUL-terminated
    return true;
}

/// "super+shift+q" into buf, like snprintf: the length it needs, without the NUL.
export fn duckwm_format_combo(mods: u32, key: [*:0]const u8, buf: ?[*]u8, len: usize) usize {
    var w: std.Io.Writer.Discarding = .init(&.{});
    const combo: duckwm.KeyCombo = .{ .mods = .from_bits(mods), .key = std.mem.span(key) };
    combo.format(&w.writer) catch unreachable;
    const need: usize = @intCast(w.count);
    if (buf) |b| if (len > 0) {
        var fixed: std.Io.Writer = .fixed(b[0 .. len - 1]);
        combo.format(&fixed) catch {};
        b[fixed.end] = 0;
    };
    return need;
}

export fn duckwm_bind_key(conn: *Conn, combo: [*:0]const u8, h: Handler, userdata: ?*anyopaque) Status {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const k = duckwm.KeyCombo.parse(std.mem.span(combo)) catch |err| return conn.fail(err);
    const id = duckwm_register(conn, h, userdata);
    if (id == 0) return conn.fail(error.OutOfMemory);
    _ = conn.c.run_one(
        arena.allocator(),
        .{ .bind = .{
            .mods = k.mods.bits(),
            .key = k.key,
            .callback = .{ .id = id },
        } },
    ) catch |err| return conn.fail(err);
    return .ok;
}

export fn duckwm_bind_key_commands(conn: *Conn, combo: [*:0]const u8, cmds: ?[*]const ct.duckwm_command, n: usize) Status {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const zcmds = list_from_c(protocol.Command, a, cmds, n) catch |err| return conn.fail(err);
    conn.c.bind_commands(a, std.mem.span(combo), zcmds) catch |err| return conn.fail(err);
    return .ok;
}

// ---- values, and which duckwm ----
/// A map's field, or NULL.
export fn duckwm_value_get(v: ?*const ct.duckwm_value, key: [*:0]const u8) ?*const ct.duckwm_value {
    const m = v orelse return null;
    if (m.kind != .map) return null;
    const items = m.u.map.items orelse return null;
    for (items[0..m.u.map.len]) |*f| {
        if (f.key) |k| if (std.mem.orderZ(u8, k, key) == .eq) return &f.value;
    }
    return null;
}

export fn duckwm_get_platform(conn: *const Conn) c_int {
    return @backingInt(conn.c.platform());
}

export fn duckwm_startup(conn: *Conn) bool {
    return conn.c.startup();
}

// ---- geometry ----
const Rect = duckwm.Rect;

export fn duckwm_rect_cut(r: ct.duckwm_rect, side: ct.duckwm_side, frac: f64, px: u32, piece: ?*ct.duckwm_rect, rest: ?*ct.duckwm_rect) void {
    const s = std.enums.fromInt(protocol.Side, @backingInt(side)) orelse return;
    const amount: duckwm.geometry.Amount = if (px > 0) .{ .px = px } else .{ .frac = frac };
    const p, const q = rect(r).cut(s, amount);
    if (piece) |o| o.* = c_rect(p);
    if (rest) |o| o.* = c_rect(q);
}

/// n pieces by ratios into out (room for n).
export fn duckwm_rect_split(r: ct.duckwm_rect, axis: ct.duckwm_axis, ratios: [*]const f64, n: usize, out: [*]ct.duckwm_rect) void {
    const ax = std.enums.fromInt(protocol.Axis, @backingInt(axis)) orelse return;
    const parts = rect(r).split(gpa, ax, ratios[0..n]) catch return;
    defer gpa.free(parts);
    for (parts, out[0..n]) |p, *o| o.* = c_rect(p);
}

/// rows x cols cells, row by row, into out (room for rows * cols).
export fn duckwm_rect_grid(r: ct.duckwm_rect, rows: usize, cols: usize, out: [*]ct.duckwm_rect) void {
    const cells = rect(r).grid(gpa, rows, cols) catch return;
    defer gpa.free(cells);
    for (cells, out[0 .. rows * cols]) |p, *o| o.* = c_rect(p);
}

fn rect(r: ct.duckwm_rect) Rect {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

fn c_rect(r: Rect) ct.duckwm_rect {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

// ---- arrangers ----
const ArrangeFn = *const fn (userdata: ?*anyopaque, ar: *Arrange) callconv(.c) void;

/// duckwm_arranger: a C arrange function, or one of the library's layouts.
const CArranger = struct {
    z: duckwm.Arranger,
    f: ?ArrangeFn = null,
    userdata: ?*anyopaque = null,
    name: ?[:0]u8 = null,

    fn call(ca: *CArranger, s: *const duckwm.Snapshot, a: Allocator) anyerror!duckwm.Reply {
        var ar: Arrange = .{ .s = s, .reply = .{ .a = a } };
        ca.f.?(ca.userdata, &ar);
        if (ar.reply.bad) |why| return .{ .err = why };
        ar.reply.r.commands = ar.reply.commands.items;
        return ar.reply.r;
    }
};

var tile_arranger: CArranger = .{ .z = duckwm.layouts.tile };
var fair_arranger: CArranger = .{ .z = duckwm.layouts.fair };

export fn duckwm_tile() *const CArranger {
    return &tile_arranger;
}

export fn duckwm_fair() *const CArranger {
    return &fair_arranger;
}

export fn duckwm_arranger_new(name: [*:0]const u8, f: ArrangeFn, userdata: ?*anyopaque) ?*CArranger {
    const ca = gpa.create(CArranger) catch return null;
    const owned = gpa.dupeSentinel(u8, std.mem.span(name), 0) catch {
        gpa.destroy(ca);
        return null;
    };
    ca.* = .{ .z = undefined, .f = f, .userdata = userdata, .name = owned };
    ca.z = .of(owned, CArranger, ca, CArranger.call);
    return ca;
}

/// After duckwm_close: duckwm may still call an arranger until then.
export fn duckwm_arranger_free(ca: ?*CArranger) void {
    const p = ca orelse return;
    if (p == &tile_arranger or p == &fair_arranger) return;
    if (p.name) |n| gpa.free(n);
    gpa.destroy(p);
}

export fn duckwm_use_arranger(conn: *Conn, ca: *const CArranger) Status {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    conn.c.set_arranger(arena.allocator(), ca.z) catch |err| return conn.fail(err);
    return .ok;
}

export fn duckwm_use_arranger_on(conn: *Conn, id: u32, ca: *const CArranger) Status {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    conn.c.register_arranger(arena.allocator(), id, ca.z) catch |err| return conn.fail(err);
    return .ok;
}

export fn duckwm_use_default_arranger(conn: *Conn, ca: *const CArranger) Status {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    conn.c.default_arranger(arena.allocator(), ca.z) catch |err| return conn.fail(err);
    return .ok;
}

/// duckwm_arrange: one call of a C arranger.
const Arrange = struct {
    s: *const duckwm.Snapshot,
    reply: Reply,
    raw: ?*const ct.duckwm_snapshot = null,
};

/// duckwm_tree: a row, a column or a window, put together in C and turned
/// into a duckwm.tree.Tree (with its rules: empty is nothing, one child is
/// the child) by duckwm_arrange_tree.
const CTree = struct {
    window: ?u32 = null,
    axis: protocol.Axis = .h,
    kids: []const ?*CTree = &.{},
    ratios: ?[]const f64 = null,
    key: ?u32 = null,

    fn tree(t: *const CTree, a: Allocator) Allocator.Error!?duckwm.tree.Tree {
        if (t.window) |w| return duckwm.tree.window(w);
        const kids = try a.alloc(?duckwm.tree.Tree, t.kids.len);
        for (kids, t.kids) |*k, c| k.* = if (c) |ct_| try ct_.tree(a) else null;
        const opts: duckwm.tree.Options = .{ .ratios = t.ratios, .key = t.key };
        return if (t.axis == .h) duckwm.tree.row(a, kids, opts) else duckwm.tree.col(a, kids, opts);
    }
};

export fn duckwm_arrange_snapshot(ar: *Arrange) ?*const ct.duckwm_snapshot {
    if (ar.raw == null) {
        const p = ar.reply.a.create(ct.duckwm_snapshot) catch return null;
        p.* = to_c(ct.duckwm_snapshot, ar.reply.a, ar.s.raw) catch return null;
        ar.raw = p;
    }
    return ar.raw;
}

/// The tiled windows, without one being unmapped.
export fn duckwm_arrange_windows(ar: *const Arrange, n: *usize) [*]const u32 {
    n.* = ar.s.windows.len;
    return ar.s.windows.ptr;
}

/// The work area relative to itself: what window constraints are measured in.
export fn duckwm_arrange_area(ar: *const Arrange) ct.duckwm_rect {
    return c_rect(ar.s.area());
}

export fn duckwm_arrange_event(ar: *const Arrange) ct.duckwm_arranger_event {
    return @fromBackingInt(@intCast(@backingInt(ar.s.event)));
}

/// Last time's order (the ids this arranger kept as its state), minus closed
/// windows, plus new ones after the window that was focused.
export fn duckwm_arrange_track(ar: *Arrange, n: *usize) ?[*]const u32 {
    const a = ar.reply.a;
    const old = (duckwm.value.ids(a, ar.s.state) catch return null) orelse &.{};
    const order = duckwm.arrange.track(a, ar.s, old) catch return null;
    n.* = order.len;
    return order.ptr;
}

export fn duckwm_tree_window(ar: *Arrange, id: u32) ?*CTree {
    const t = ar.reply.a.create(CTree) catch return null;
    t.* = .{ .window = id };
    return t;
}

fn branch(ar: *Arrange, axis: protocol.Axis, kids: ?[*]const ?*CTree, n: usize) ?*CTree {
    const a = ar.reply.a;
    const t = a.create(CTree) catch return null;
    t.* = .{ .axis = axis, .kids = a.dupe(?*CTree, if (kids) |k| k[0..n] else &.{}) catch return null };
    return t;
}

/// Children side by side; NULL children are skipped.
export fn duckwm_tree_row(ar: *Arrange, kids: ?[*]const ?*CTree, n: usize) ?*CTree {
    return branch(ar, .h, kids, n);
}

/// Children stacked top to bottom.
export fn duckwm_tree_col(ar: *Arrange, kids: ?[*]const ?*CTree, n: usize) ?*CTree {
    return branch(ar, .v, kids, n);
}

/// A row or column of these windows.
export fn duckwm_tree_windows(ar: *Arrange, axis: ct.duckwm_axis, ids: ?[*]const u32, n: usize) ?*CTree {
    const a = ar.reply.a;
    const kids = a.alloc(?*CTree, n) catch return null;
    for (kids, 0..) |*k, i| k.* = duckwm_tree_window(ar, ids.?[i]) orelse return null;
    return branch(ar, std.enums.fromInt(protocol.Axis, @backingInt(axis)) orelse return null, kids.ptr, n);
}

/// Shares of a row or column; ignored unless there's one per child. Copied.
export fn duckwm_tree_ratios(ar: *Arrange, t: ?*CTree, ratios: [*]const f64, n: usize) void {
    const p = t orelse return;
    p.ratios = ar.reply.a.dupe(f64, ratios[0..n]) catch return;
}

/// A key of its own for a row or column, instead of the depth-first one.
export fn duckwm_tree_key(t: ?*CTree, key: u32) void {
    if (t) |p| p.key = key;
}

/// The layout, from a tree (NULL: no windows); a newly mapped window gets focus.
export fn duckwm_arrange_tree(ar: *Arrange, t: ?*const CTree) Status {
    const a = ar.reply.a;
    return ar.reply.set(blk: {
        const zt = if (t) |p| p.tree(a) catch |err| break :blk err else null;
        const r = duckwm.tree.reply(a, ar.s, zt, null) catch |err| break :blk err;
        ar.reply.r.layout = r.layout;
        break :blk ar.reply.commands.appendSlice(a, r.commands);
    });
}

/// Keep these ids as the state (what duckwm_arrange_track reads next time).
export fn duckwm_arrange_keep_ids(ar: *Arrange, ids: ?[*]const u32, n: usize) Status {
    return ar.reply.set(blk: {
        const v = duckwm.value.from_ids(ar.reply.a, if (ids) |p| p[0..n] else &.{}) catch |err| break :blk err;
        ar.reply.r.state = v;
    });
}

/// The reply underneath, for duckwm_reply_command, _layout, _state or _error.
export fn duckwm_arrange_reply(ar: *Arrange) *Reply {
    return &ar.reply;
}

// ---- for good ----
const SetupFn = *const fn (userdata: ?*anyopaque, c: *Conn) callconv(.c) Status;

/// Connect, setup, serve; when duckwm goes away, wait for it and do it all
/// again. A setup that fails is retried with a growing delay.
export fn duckwm_forever(setup: SetupFn, userdata: ?*anyopaque) noreturn {
    const path = duckwm.socket_path(gpa) catch @panic("out of memory");
    var delay: u64 = 1;
    var waiting = false;
    while (true) {
        const conn = Conn.create(duckwm.Client.connect_to(gpa, path) catch {
            if (!waiting) std.debug.print("duckwm: waiting for duckwm\n", .{});
            waiting = true;
            sleep(1);
            continue;
        }) orelse @panic("out of memory");
        defer duckwm_close(conn);
        waiting = false;
        std.debug.print("duckwm: connected\n", .{});
        switch (setup(userdata, conn)) {
            .ok => {
                delay = 1;
                _ = duckwm_serve(conn);
                std.debug.print("duckwm: disconnected\n", .{});
                continue;
            },
            .closed => {
                std.debug.print("duckwm: disconnected\n", .{});
                continue;
            },
            else => std.debug.print("duckwm: setup failed: {s}\n", .{duckwm_last_error(conn)}),
        }
        sleep(delay);
        delay = @min(delay * 2, 30);
    }
}

fn sleep(seconds: u64) void {
    const ts: std.os.linux.timespec = .{ .sec = @intCast(seconds), .nsec = 0 };
    _ = std.os.linux.nanosleep(&ts, null);
}

// ---- tests: the C functions against a fake duckwm on a socket pair ----
const testing = std.testing;
const linux = std.os.linux;
const wire = protocol.wire;

const Fake = struct {
    fd: i32,
    arena: std.heap.ArenaAllocator = .init(testing.allocator),

    fn frame(f: *Fake, body: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(body.len), .little);
        _ = linux.write(f.fd, &len, 4);
        _ = linux.write(f.fd, body.ptr, body.len);
    }

    fn respond(f: *Fake, results: []const protocol.Value, err: ?[]const u8) !void {
        try f.frame(try wire.encode_server_response(f.arena.allocator(), results, err));
    }

    fn call(f: *Fake, callback: u64, args: protocol.CallArgs) !void {
        try f.frame(try wire.encode_server_call(f.arena.allocator(), .{ .callback = callback, .args = args, .nested = true }));
    }

    fn recv(f: *Fake) !protocol.ClientMessage {
        const a = f.arena.allocator();
        var len: [4]u8 = undefined;
        _ = linux.read(f.fd, &len, 4);
        const body = try a.alloc(u8, std.mem.readInt(u32, &len, .little));
        _ = linux.read(f.fd, body.ptr, body.len);
        return wire.decode_client_message(body, a);
    }
};

fn pair() !struct { *Conn, Fake } {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS)
        return error.SocketFailed;
    return .{ Conn.create(.from_core(gpa, .from_fd(gpa, fds[0]))).?, .{ .fd = fds[1] } };
}

fn teardown(conn: *Conn, f: *Fake) void {
    duckwm_close(conn);
    _ = linux.close(f.fd);
    f.arena.deinit();
}

test "commands in, values out" {
    const conn, var f = try pair();
    defer teardown(conn, &f);

    const argv = [_][*:0]const u8{ "foot", "-e", "htop" };
    const cmds = [_]ct.duckwm_command{
        .{ .kind = .focus, .u = .{ .focus = .{ .id = 3 } } },
        .{
            .kind = .spawn,
            .u = .{ .spawn = .{
                .argv = &argv,
                .argv_len = argv.len,
            } },
        },
        .{ .kind = .get_keybinds, .u = undefined },
    };
    const binds = [_]protocol.Value.Field{
        .{ .key = "mods", .value = .{ .integer = 64 } },
        .{ .key = "key", .value = .{ .str = "q" } },
    };
    try f.respond(&.{ .nil, .nil, .{ .list = &.{.{ .map = &binds }} } }, null);

    var res: Results = undefined;
    try testing.expectEqual(Status.ok, duckwm_run(conn, &cmds, cmds.len, &res));
    defer duckwm_results_free(&res);

    const sent = (try f.recv()).request.commands;
    try testing.expectEqual(@as(u32, 3), sent[0].focus.id);
    try testing.expectEqualStrings("htop", sent[1].spawn.argv[2]);
    try testing.expect(sent[2] == .get_keybinds);

    try testing.expectEqual(@as(usize, 3), res.len);
    const list = res.values.?[2];
    try testing.expectEqual(ct.duckwm_value_kind.list, list.kind);
    const field = list.u.list.items.?[0].u.map.items.?[1];
    try testing.expectEqualStrings("key", std.mem.span(field.key.?));
    try testing.expectEqualStrings("q", std.mem.span(field.value.u.str.?));
}

test "a rejection, and what C gets wrong" {
    const conn, var f = try pair();
    defer teardown(conn, &f);

    try f.respond(&.{}, "no such node");
    const focus = ct.duckwm_command{
        .kind = .focus,
        .u = .{ .focus = .{ .id = 99 } },
    };
    try testing.expectEqual(Status.rejected, duckwm_run(conn, @ptrCast(&focus), 1, null));
    try testing.expectEqualStrings("no such node", std.mem.span(duckwm_last_error(conn)));

    // Nothing reaches duckwm for these: rejected before sending.
    const bad_kind = ct.duckwm_command{ .kind = @fromBackingInt(@intCast(9999)), .u = undefined };
    try testing.expectEqual(Status.invalid, duckwm_run(conn, @ptrCast(&bad_kind), 1, null));
    var null_key = std.mem.zeroes(ct.duckwm_command);
    null_key.kind = .bind;
    try testing.expectEqual(Status.invalid, duckwm_run(conn, @ptrCast(&null_key), 1, null));
}

const OnKey = struct {
    var presses: usize = 0;

    fn on(ud: ?*anyopaque, c: *Conn, args: *const ct.duckwm_call_args, reply: *Reply) callconv(.c) void {
        _ = ud;
        presses += 1;
        std.debug.assert(args.kind == .key);
        // A request inside the call, then a reply from a local that's gone
        // once we return: the reply copied it.
        const get = ct.duckwm_command{ .kind = .get_focused, .u = undefined };
        var res: Results = undefined;
        if (duckwm_run(c, @ptrCast(&get), 1, &res) != .ok) return;
        defer duckwm_results_free(&res);
        var kill = std.mem.zeroes(ct.duckwm_command);
        kill.kind = .kill_client;
        _ = duckwm_reply_command(reply, kill);
        var bad = kill;
        bad.kind = @fromBackingInt(@intCast(9999));
        if (duckwm_reply_command(reply, bad) != .invalid) unreachable;
        if (res.values.?[0].u.integer != 7) _ = duckwm_reply_error(reply, "wrong window");
    }
};

test "a C callback, its nested request, and its reply" {
    const conn, var f = try pair();
    defer teardown(conn, &f);
    const id = duckwm_register(conn, OnKey.on, null);
    try testing.expect(id != 0);

    try f.call(id, .key);
    try f.respond(&.{.{ .integer = 7 }}, null);
    try testing.expectEqual(Status.ok, duckwm_dispatch(conn));
    try testing.expectEqual(@as(usize, 1), OnKey.presses);

    try testing.expect((try f.recv()).request.commands[0] == .get_focused);
    // The bad command failed the whole reply: duckwm undoes the transaction.
    const ret = (try f.recv()).ret;
    try testing.expectEqualStrings("the callback's reply holds an invalid command or value", ret.err.?);

    duckwm_unregister(conn, id);
    try f.call(id, .key);
    try testing.expectEqual(Status.ok, duckwm_dispatch(conn));
    try testing.expectEqualStrings("no such callback", (try f.recv()).ret.err.?);
}

test "combos, values and rects from C" {
    var mods: u32 = 0;
    var key: ?[*:0]const u8 = null;
    try testing.expect(duckwm_parse_combo("shift+super+q", &mods, &key));
    try testing.expectEqual(@as(u32, 65), mods);
    try testing.expectEqualStrings("q", std.mem.span(key.?));
    try testing.expect(!duckwm_parse_combo("hyper+q", null, null));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), duckwm_format_combo(65, "q", &buf, buf.len));
    try testing.expectEqualStrings("super+s", std.mem.span(@as([*:0]u8, @ptrCast(&buf)))); // cut to fit

    const fields = [_]ct.duckwm_value_field{.{
        .key = "mods",
        .value = .{ .kind = .integer, .u = .{ .integer = 64 } },
    }};
    const map: ct.duckwm_value = .{
        .kind = .map,
        .u = .{ .map = .{ .items = &fields, .len = 1 } },
    };
    try testing.expectEqual(@as(i64, 64), duckwm_value_get(&map, "mods").?.u.integer);
    try testing.expectEqual(@as(?*const ct.duckwm_value, null), duckwm_value_get(&map, "key"));

    var out: [3]ct.duckwm_rect = undefined;
    duckwm_rect_split(.{ .x = 0, .y = 0, .width = 100, .height = 10 }, .h, &[_]f64{ 1, 1, 1 }, 3, &out);
    try testing.expectEqual(@as(u32, 33), out[0].width);
    try testing.expectEqual(@as(i32, 67), out[2].x);
}

/// A C arranger: every window side by side, in tracked order.
fn columns(_: ?*anyopaque, ar: *Arrange) callconv(.c) void {
    var n: usize = 0;
    const order = duckwm_arrange_track(ar, &n).?;
    _ = duckwm_arrange_tree(ar, duckwm_tree_windows(ar, .h, order, n));
    _ = duckwm_arrange_keep_ids(ar, order, n);
}

test "a C arranger, through the handshake" {
    const conn, var f = try pair();
    defer teardown(conn, &f);
    const ca = duckwm_arranger_new("columns", columns, null).?;
    defer duckwm_arranger_free(ca);

    try f.respond(&.{.nil}, null);
    try testing.expectEqual(Status.ok, duckwm_use_arranger(conn, ca));
    const set = (try f.recv()).request.commands[0].set_arranger;
    try testing.expectEqualStrings("columns", set.name.?);

    try f.call(set.factory.id, .factory);
    try testing.expectEqual(Status.ok, duckwm_dispatch(conn));
    const arranger = (try f.recv()).ret.callback.?;

    const geo: protocol.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const ws = [_]protocol.WindowInfo{
        .{ .id = 1, .geometry = geo },
        .{ .id = 2, .geometry = geo },
        .{ .id = 3, .geometry = geo },
    };
    const state = [_]protocol.Value{ .{ .integer = 2 }, .{ .integer = 1 } };
    try f.call(arranger, .{ .arranger = .{
        .event = .map,
        .id = 3,
        .prev_id = 2,
        .work_area = .{ .x = 0, .y = 0, .width = 900, .height = 500 },
        .cursor_dx = 0,
        .cursor_dy = 0,
        .focused = 2,
        .windows = &ws,
        .layout = .{ .nodes = &.{} },
        .state = .{ .list = &state },
    } });
    try testing.expectEqual(Status.ok, duckwm_dispatch(conn));
    const ret = (try f.recv()).ret;
    try testing.expectEqual(@as(?[]const u8, null), ret.err);
    try testing.expectEqual(@as(u32, 3), ret.commands[0].focus.id); // mapped: focused
    // 3 went after 2, the focused one.
    const kept = ret.state.?.list;
    try testing.expectEqual(@as(i64, 2), kept[0].integer);
    try testing.expectEqual(@as(i64, 3), kept[1].integer);
    try testing.expectEqual(@as(i64, 1), kept[2].integer);
    const root = ret.layout.?.nodes[0].constraints.?;
    const split = root[root.len - 1].split;
    try testing.expectEqual(@as(usize, 3), split.children.len);
    try testing.expectEqual(@as(u32, 3), split.children[1].id);
}
