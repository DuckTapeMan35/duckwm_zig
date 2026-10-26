//! Writes the C API's types from duckwm's protocol.zig (src/upstream), twice
//! from one walk so the two can't disagree: include/duckwm.h for C, and
//! src/c_types.zig, the same types as Zig extern declarations for src/c.zig.
//! Run by `zig build c`.
//!
//! The mapping, field by field:
//!   bool, ints, floats      bool, (u)intN_t, float/double
//!   []const u8              const char * (NUL-terminated)
//!   []const T               const T *x; size_t x_len;
//!   ?T for a scalar or enum bool has_x; T x;
//!   ?T for anything else    a pointer, NULL when absent
//!   enum                    a C enum, DUCKWM_<TYPE>_<VALUE>
//!   struct                  a struct
//!   union(enum)             struct { kind; union { ... }; }, kind DUCKWM_<TYPE>_<VARIANT>;
//!                           a list payload is a struct { items; len; }
//!
//! On the Zig side every string is `?[*:0]const u8` and every enum is
//! non-exhaustive: C can leave a string NULL or put any int in an enum, and
//! src/c.zig turns those into DUCKWM_INVALID rather than trusting them.

const std = @import("std");
const protocol = @import("upstream/protocol.zig");

const common = @import("upstream/gen_common.zig");
const pascal = common.pascal;
const snake = common.snake;
const screaming = common.screaming;
const is_string = common.is_string;
const is_list = common.is_list;

const Command = protocol.Command;

/// A type the API declares, with its C name minus "duckwm_".
const Named = common.Named;

// ---- names ----
/// A named type keeps its Zig name (protocol.Value.Field: ValueField); an
/// anonymous one is named from its context.
fn type_name(comptime T: type, comptime fallback: []const u8) []const u8 {
    comptime {
        const full = @typeName(T);
        if (std.mem.indexOf(u8, full, "__") != null) return fallback;
        var name: []const u8 = "";
        // "protocol.Value.Field", or "upstream.protocol.Value.Field" from here.
        const start = if (std.mem.indexOf(u8, full, "protocol.")) |p| p + "protocol.".len else 0;
        for (full[start..]) |ch| {
            if (ch != '.') name = name ++ [_]u8{ch};
        }
        return name;
    }
}

const c_keywords = [_][]const u8{
    "auto",     "break",  "case",   "char",     "const",    "continue", "default",  "do",
    "double",   "else",   "enum",   "extern",   "float",    "for",      "goto",     "if",
    "inline",   "int",    "long",   "register", "restrict", "return",   "short",    "signed",
    "sizeof",   "static", "struct", "switch",   "typedef",  "union",    "unsigned", "void",
    "volatile", "while",  "bool",   "true",     "false",
};

fn c_ident(comptime s: []const u8) []const u8 {
    comptime {
        for (c_keywords) |k| if (std.mem.eql(u8, s, k)) @compileError("field '" ++ s ++ "' is a C keyword; rename it");
        return s;
    }
}

// ---- kinds of types ----
fn is_compound(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        else => false,
    };
}

// ---- collecting ----
/// T and everything it refers to, each once, into acc.
fn collect(comptime T: type, comptime ctx: []const u8, comptime acc: []const Named) []const Named {
    switch (@typeInfo(T)) {
        .optional => |o| return collect(o.child, ctx, acc),
        .pointer => |p| return if (is_string(T)) acc else collect(p.child, ctx, acc),
        .@"enum", .@"struct", .@"union" => {},
        else => return acc,
    }
    for (acc) |n| if (n.T == T) return acc;
    const name = type_name(T, ctx);
    // Added before its fields, so recursive types (Value, Command) stop here.
    var out: []const Named = acc ++ [_]Named{.{ .T = T, .name = snake(name) }};
    switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.field_names, s.field_types) |f_name, f_type| {
            out = collect(f_type, name ++ pascal(f_name), out);
        },
        .@"union" => |u| for (u.field_names, u.field_types) |f_name, f_type| {
            // A command's payload is its arguments: focus_args, spawn_args...
            const sub = if (T == Command) pascal(f_name) ++ "Args" else name ++ pascal(f_name);
            if (f_type != void) out = collect(f_type, sub, out);
        },
        else => {},
    }
    return out;
}

/// Everything the C API exposes: commands, values, and what callbacks receive.
const all_types = blk: {
    @setEvalBranchQuota(10_000_000);
    var acc: []const Named = &.{};
    acc = collect(Command, "Command", acc);
    acc = collect(protocol.Value, "Value", acc);
    acc = collect(protocol.CallArgs, "CallArgs", acc);
    acc = collect(protocol.LayoutSpec, "LayoutSpec", acc);
    break :blk acc;
};

fn name_of(comptime T: type) []const u8 {
    comptime {
        for (all_types) |n| if (n.T == T) return n.name;
        @compileError("not collected: " ++ @typeName(T));
    }
}

// ---- spelling a type ----
/// T as a C type, for a field holding exactly one T.
fn c_type(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "int" else "uint") ++ std.fmt.comptimePrint("{d}", .{i.bits}) ++ "_t",
        .float => |f| if (f.bits == 32) "float" else "double",
        .pointer => if (is_string(T)) "const char *" else @compileError("nested list"),
        .@"enum", .@"struct", .@"union" => "duckwm_" ++ name_of(T),
        else => @compileError("no C mapping for " ++ @typeName(T)),
    };
}

/// The same for Zig.
fn z_type(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "i" else "u") ++ std.fmt.comptimePrint("{d}", .{i.bits}),
        .float => |f| std.fmt.comptimePrint("f{d}", .{f.bits}),
        .pointer => if (is_string(T)) "?[*:0]const u8" else @compileError("nested list"),
        .@"enum", .@"struct", .@"union" => "duckwm_" ++ name_of(T),
        else => @compileError("no Zig mapping for " ++ @typeName(T)),
    };
}

/// A pointer to many E, in C: `const E *` (`const char *const *` for strings).
fn c_many(comptime E: type) []const u8 {
    return if (is_string(E)) "const char *const *" else "const " ++ c_type(E) ++ " *";
}

fn z_many(comptime E: type) []const u8 {
    return "?[*]const " ++ z_type(E);
}

// ---- writing ----
const Out = struct {
    a: std.mem.Allocator,
    h: std.ArrayListUnmanaged(u8) = .empty,
    z: std.ArrayListUnmanaged(u8) = .empty,

    // Everything printed is known at compile time: the text is built then.
    fn c(o: *Out, comptime fmt: []const u8, comptime args: anytype) !void {
        try o.h.appendSlice(o.a, comptime std.fmt.comptimePrint(fmt, args));
    }

    fn zig(o: *Out, comptime fmt: []const u8, comptime args: anytype) !void {
        try o.z.appendSlice(o.a, comptime std.fmt.comptimePrint(fmt, args));
    }
};

/// One struct field, in both languages.
fn emit_field(o: *Out, comptime F: type, comptime f: []const u8) !void {
    const name = comptime c_ident(f);
    switch (@typeInfo(F)) {
        .optional => |opt| {
            const O = opt.child;
            if (comptime is_string(O)) {
                try o.c("    const char *{s};\n", .{name});
                try o.zig("    @\"{s}\": ?[*:0]const u8,\n", .{f});
            } else if (comptime is_list(O)) {
                try emit_list(o, @typeInfo(O).pointer.child, f);
            } else if (comptime is_compound(O)) {
                try o.c("    const {s} *{s};\n", .{ c_type(O), name });
                try o.zig("    @\"{s}\": ?*const {s},\n", .{ f, z_type(O) });
            } else {
                try o.c("    bool has_{s};\n    {s} {s};\n", .{ name, c_type(O), name });
                try o.zig("    has_{s}: bool,\n    @\"{s}\": {s},\n", .{ f, f, z_type(O) });
            }
        },
        .pointer => |p| if (comptime is_string(F)) {
            try o.c("    const char *{s};\n", .{name});
            try o.zig("    @\"{s}\": ?[*:0]const u8,\n", .{f});
        } else try emit_list(o, p.child, f),
        else => {
            try o.c("    {s} {s};\n", .{ c_type(F), name });
            try o.zig("    @\"{s}\": {s},\n", .{ f, z_type(F) });
        },
    }
}

fn emit_list(o: *Out, comptime E: type, comptime f: []const u8) !void {
    try o.c("    {s}{s};\n    size_t {s}_len;\n", .{ c_many(E), (comptime c_ident(f)), f });
    try o.zig("    @\"{s}\": {s},\n    {s}_len: usize,\n", .{ f, z_many(E), f });
}

fn emit_enum(o: *Out, comptime n: Named) !void {
    const e = @typeInfo(n.T).@"enum";
    try o.c("typedef enum duckwm_{s} {{\n", .{n.name});
    try o.zig("pub const duckwm_{s} = enum(c_int) {{\n", .{n.name});
    inline for (e.field_names, e.field_values) |f, v| {
        try o.c("    DUCKWM_{s}_{s} = {d},\n", .{ comptime screaming(n.name), comptime screaming(f), v });
        try o.zig("    @\"{s}\" = {d},\n", .{ f, v });
    }
    try o.c("}} duckwm_{s};\n\n", .{n.name});
    try o.zig("    _,\n}};\n\n", .{});
}

/// A union's kind enum: its variants, valued as the union's tag.
fn emit_kind(o: *Out, comptime n: Named) !void {
    const u = @typeInfo(n.T).@"union";
    const tag = @typeInfo(u.tag_type.?).@"enum";
    try o.c("typedef enum duckwm_{s}_kind {{\n", .{n.name});
    try o.zig("pub const duckwm_{s}_kind = enum(c_int) {{\n", .{n.name});
    inline for (u.field_names) |f| {
        const v = comptime blk: {
            for (tag.field_names, tag.field_values) |tn, tv| if (std.mem.eql(u8, tn, f)) break :blk tv;
            unreachable;
        };
        try o.c("    DUCKWM_{s}_{s} = {d},\n", .{ comptime screaming(n.name), comptime screaming(f), v });
        try o.zig("    @\"{s}\" = {d},\n", .{ f, v });
    }
    try o.c("}} duckwm_{s}_kind;\n\n", .{n.name});
    try o.zig("    _,\n}};\n\n", .{});
}

fn emit_struct(o: *Out, comptime n: Named) !void {
    const s = @typeInfo(n.T).@"struct";
    try o.c("struct duckwm_{s} {{\n", .{n.name});
    try o.zig("pub const duckwm_{s} = extern struct {{\n", .{n.name});
    if (s.field_names.len == 0) {
        try o.c("    char _unused;\n", .{});
        try o.zig("    _unused: u8 = 0,\n", .{});
    }
    inline for (s.field_names, s.field_types) |f, F| try emit_field(o, F, f);
    try o.c("}};\n\n", .{});
    try o.zig("}};\n\n", .{});
}

fn emit_union(o: *Out, comptime n: Named) !void {
    const u = @typeInfo(n.T).@"union";
    // A list payload gets a struct of its own: duckwm_value_list.
    inline for (u.field_names, u.field_types) |f, F| {
        if (comptime is_list(F)) {
            const E = @typeInfo(F).pointer.child;
            try o.c("typedef struct duckwm_{s}_{s} {{\n    {s}items;\n    size_t len;\n}} duckwm_{s}_{s};\n\n", .{ n.name, f, c_many(E), n.name, f });
            try o.zig("pub const duckwm_{s}_{s} = extern struct {{\n    items: {s},\n    len: usize,\n}};\n\n", .{ n.name, f, z_many(E) });
        }
    }
    try o.c("struct duckwm_{s} {{\n    duckwm_{s}_kind kind;\n    union {{\n", .{ n.name, n.name });
    try o.zig("pub const duckwm_{s} = extern struct {{\n    kind: duckwm_{s}_kind,\n    u: extern union {{\n", .{ n.name, n.name });
    var members: usize = 0;
    inline for (u.field_names, u.field_types) |f, F| {
        if (F == void) continue;
        members += 1;
        const name = comptime c_ident(f);
        if (comptime is_list(F)) {
            try o.c("        duckwm_{s}_{s} {s};\n", .{ n.name, f, name });
            try o.zig("        @\"{s}\": duckwm_{s}_{s},\n", .{ f, n.name, f });
        } else if (@typeInfo(F) == .optional) {
            @compileError("optional union payload in " ++ @typeName(n.T));
        } else if (comptime is_string(F)) {
            try o.c("        const char *{s};\n", .{name});
            try o.zig("        @\"{s}\": ?[*:0]const u8,\n", .{f});
        } else {
            try o.c("        {s} {s};\n", .{ c_type(F), name });
            try o.zig("        @\"{s}\": {s},\n", .{ f, z_type(F) });
        }
    }
    if (members == 0) {
        try o.c("        char _unused;\n", .{});
        try o.zig("        _unused: u8,\n", .{});
    }
    try o.c("    }};\n}};\n\n", .{});
    try o.zig("    }},\n}};\n\n", .{});
}

/// The compound types T holds directly (not behind a pointer).
fn inline_deps(comptime T: type) []const type {
    comptime {
        var out: []const type = &.{};
        switch (@typeInfo(T)) {
            .@"struct" => |s| for (s.field_types) |F| {
                if (is_compound(F)) out = out ++ [_]type{F};
            },
            .@"union" => |u| for (u.field_types) |F| {
                if (is_compound(F)) out = out ++ [_]type{F};
            },
            else => {},
        }
        return out;
    }
}

/// Structs and unions, each after the ones it holds directly.
const definition_order = blk: {
    @setEvalBranchQuota(10_000_000);
    var done: []const type = &.{};
    var order: []const Named = &.{};
    var progress = true;
    while (progress) {
        progress = false;
        for (all_types) |n| {
            if (!is_compound(n.T)) continue;
            if (std.mem.indexOfScalar(type, done, n.T) != null) continue;
            const ready = for (inline_deps(n.T)) |d| {
                if (d != n.T and std.mem.indexOfScalar(type, done, d) == null) break false;
            } else true;
            if (ready) {
                done = done ++ [_]type{n.T};
                order = order ++ [_]Named{n};
                progress = true;
            }
        }
    }
    for (all_types) |n| {
        if (is_compound(n.T) and std.mem.indexOfScalar(type, done, n.T) == null)
            @compileError("types that hold each other directly: " ++ @typeName(n.T));
    }
    break :blk order;
};

const c_prologue =
    \\/* Generated by `zig build c` from duckwm's protocol.zig. Do not edit.
    \\ *
    \\ * duckwm's C API: commands are values (duckwm_command), run as one
    \\ * transaction with duckwm_run. See the end of this file for the functions.
    \\ */
    \\#ifndef DUCKWM_H
    \\#define DUCKWM_H
    \\
    \\#include <stdbool.h>
    \\#include <stddef.h>
    \\#include <stdint.h>
    \\#include <string.h>
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\
;

const c_api =
    \\/* ---- the client ---- */
    \\
    \\typedef struct duckwm_client duckwm_client;
    \\
    \\typedef enum duckwm_status {
    \\    DUCKWM_OK = 0,
    \\    DUCKWM_CLOSED = 1,         /* duckwm closed the connection */
    \\    DUCKWM_REJECTED = 2,       /* duckwm refused the batch: nothing in it took effect */
    \\    DUCKWM_PROTOCOL = 3,       /* duckwm sent something that isn't the protocol */
    \\    DUCKWM_CONNECT_FAILED = 4,
    \\    DUCKWM_NO_MEMORY = 5,
    \\    DUCKWM_INVALID = 6,        /* a command with a NULL string or an unknown kind */
    \\} duckwm_status;
    \\
    \\/* What duckwm_run returns: one value per command. Free with duckwm_results_free. */
    \\typedef struct duckwm_results {
    \\    const duckwm_value *values;
    \\    size_t len;
    \\    void *_owner;
    \\} duckwm_results;
    \\
    \\/* What a callback hands back, built with duckwm_reply_* below. */
    \\typedef struct duckwm_reply duckwm_reply;
    \\
    \\/* A callback. Requests made with c inside it run in the transaction duckwm
    \\ * is waiting on. args and everything it points to live for the call. */
    \\typedef void (*duckwm_handler)(void *userdata, duckwm_client *c,
    \\                               const duckwm_call_args *args, duckwm_reply *reply);
    \\
    \\/* Connect at $XDG_RUNTIME_DIR/duckwm.sock (or /tmp/duckwm-<uid>.sock), or at
    \\ * a given path. NULL if duckwm isn't there. */
    \\duckwm_client *duckwm_connect(void);
    \\duckwm_client *duckwm_connect_to(const char *path);
    \\void duckwm_close(duckwm_client *c);
    \\
    \\/* Why the last call failed: duckwm's message after DUCKWM_REJECTED. */
    \\const char *duckwm_last_error(const duckwm_client *c);
    \\
    \\/* Run n commands as one transaction. Calls duckwm makes meanwhile (set off
    \\ * by them) are answered before it returns. */
    \\duckwm_status duckwm_run(duckwm_client *c, const duckwm_command *cmds, size_t n,
    \\                         duckwm_results *out);
    \\void duckwm_results_free(duckwm_results *r);
    \\
    \\/* A callback id for bind, add_rule, set_arranger and friends; 0 if out of memory. */
    \\uint64_t duckwm_register(duckwm_client *c, duckwm_handler h, void *userdata);
    \\void duckwm_unregister(duckwm_client *c, uint64_t id);
    \\
    \\/* Answer duckwm's calls until the connection closes (DUCKWM_CLOSED). */
    \\duckwm_status duckwm_serve(duckwm_client *c);
    \\
    \\/* For an event loop: poll duckwm_fd for reading, then duckwm_dispatch
    \\ * answers the calls waiting, without blocking for more. */
    \\int duckwm_fd(const duckwm_client *c);
    \\duckwm_status duckwm_dispatch(duckwm_client *c);
    \\
    \\/* Inside a callback: what to hand back. Each copies what it's given, so it
    \\ * can come from the stack. A command or value that won't convert fails
    \\ * duckwm's transaction (and returns DUCKWM_INVALID). */
    \\duckwm_status duckwm_reply_commands(duckwm_reply *r, const duckwm_command *cmds, size_t n);
    \\duckwm_status duckwm_reply_command(duckwm_reply *r, duckwm_command cmd); /* appends one */
    \\duckwm_status duckwm_reply_layout(duckwm_reply *r, const duckwm_layout_spec *layout); /* an arranger's */
    \\duckwm_status duckwm_reply_state(duckwm_reply *r, const duckwm_value *state); /* an arranger's next */
    \\void duckwm_reply_made(duckwm_reply *r, uint64_t arranger);  /* a factory: the arranger it made */
    \\duckwm_status duckwm_reply_error(duckwm_reply *r, const char *msg); /* fail the transaction */
    \\
    \\/* ---- keys ---- */
    \\
    \\enum {
    \\    DUCKWM_MOD_SHIFT = 1 << 0,
    \\    DUCKWM_MOD_LOCK = 1 << 1,
    \\    DUCKWM_MOD_CTRL = 1 << 2,
    \\    DUCKWM_MOD_ALT = 1 << 3,
    \\    DUCKWM_MOD_MOD2 = 1 << 4,
    \\    DUCKWM_MOD_MOD3 = 1 << 5,
    \\    DUCKWM_MOD_SUPER = 1 << 6,
    \\    DUCKWM_MOD_MOD5 = 1 << 7,
    \\};
    \\
    \\/* "super+shift+q": its modifier bits, and the key (pointing into combo). */
    \\bool duckwm_parse_combo(const char *combo, uint32_t *mods, const char **key);
    \\/* The other way, into buf like snprintf: returns the length it needs. */
    \\size_t duckwm_format_combo(uint32_t mods, const char *key, char *buf, size_t len);
    \\/* Register h and bind it to a key by name. */
    \\duckwm_status duckwm_bind_key(duckwm_client *c, const char *combo, duckwm_handler h, void *userdata);
    \\/* Bind a key to commands duckwm runs itself, so the key never waits on us. */
    \\duckwm_status duckwm_bind_key_commands(duckwm_client *c, const char *combo,
    \\                                       const duckwm_command *cmds, size_t n);
    \\
    \\/* ---- values, and which duckwm ---- */
    \\
    \\/* A map's field, or NULL (also when v isn't a map). */
    \\const duckwm_value *duckwm_value_get(const duckwm_value *v, const char *key);
    \\
    \\typedef enum duckwm_platform { DUCKWM_PLATFORM_X11 = 0, DUCKWM_PLATFORM_RIVER = 1 } duckwm_platform;
    \\duckwm_platform duckwm_get_platform(const duckwm_client *c);
    \\/* True for the first connection to this duckwm process, from any client
    \\ * library: for things to do once per session. */
    \\bool duckwm_startup(duckwm_client *c);
    \\
    \\/* ---- geometry ---- */
    \\
    \\/* Take a piece off one side: px pixels, or (px 0) a fraction of the length. */
    \\void duckwm_rect_cut(duckwm_rect r, duckwm_side side, double frac, uint32_t px,
    \\                     duckwm_rect *piece, duckwm_rect *rest);
    \\/* Side by side (h) or stacked (v) by ratios, covering r exactly; out has room for n. */
    \\void duckwm_rect_split(duckwm_rect r, duckwm_axis axis, const double *ratios, size_t n,
    \\                       duckwm_rect *out);
    \\/* rows x cols cells, row by row; out has room for rows * cols. */
    \\void duckwm_rect_grid(duckwm_rect r, size_t rows, size_t cols, duckwm_rect *out);
    \\
    \\/* ---- arrangers ----
    \\ *
    \\ * An arranger turns a workspace's snapshot into its whole layout. Write one
    \\ * as a duckwm_arrange_fn, or use duckwm_tile() or duckwm_fair(). Inside it,
    \\ * everything the duckwm_arrange_* and duckwm_tree_* functions return lives
    \\ * for the call: nothing to free.
    \\ */
    \\
    \\typedef struct duckwm_arranger duckwm_arranger;
    \\typedef struct duckwm_arrange duckwm_arrange; /* one call of an arranger */
    \\typedef struct duckwm_tree duckwm_tree;       /* a row, a column or a window */
    \\typedef void (*duckwm_arrange_fn)(void *userdata, duckwm_arrange *ar);
    \\
    \\const duckwm_arranger *duckwm_tile(void); /* master and stack */
    \\const duckwm_arranger *duckwm_fair(void); /* columns of near-equal windows */
    \\duckwm_arranger *duckwm_arranger_new(const char *name, duckwm_arrange_fn f, void *userdata);
    \\void duckwm_arranger_free(duckwm_arranger *a); /* after duckwm_close */
    \\
    \\duckwm_status duckwm_use_arranger(duckwm_client *c, const duckwm_arranger *a); /* this workspace */
    \\duckwm_status duckwm_use_arranger_on(duckwm_client *c, uint32_t id, const duckwm_arranger *a);
    \\duckwm_status duckwm_use_default_arranger(duckwm_client *c, const duckwm_arranger *a); /* and this one */
    \\
    \\const duckwm_snapshot *duckwm_arrange_snapshot(duckwm_arrange *ar); /* all of it, as duckwm sent it */
    \\duckwm_arranger_event duckwm_arrange_event(const duckwm_arrange *ar);
    \\const uint32_t *duckwm_arrange_windows(const duckwm_arrange *ar, size_t *n); /* without one unmapping */
    \\duckwm_rect duckwm_arrange_area(const duckwm_arrange *ar); /* what window constraints are measured in */
    \\/* Last time's order (the ids kept with duckwm_arrange_keep_ids), minus closed
    \\ * windows, plus new ones after the window that was focused. */
    \\const uint32_t *duckwm_arrange_track(duckwm_arrange *ar, size_t *n);
    \\
    \\duckwm_tree *duckwm_tree_window(duckwm_arrange *ar, uint32_t id);
    \\duckwm_tree *duckwm_tree_row(duckwm_arrange *ar, duckwm_tree *const *kids, size_t n); /* NULLs skipped */
    \\duckwm_tree *duckwm_tree_col(duckwm_arrange *ar, duckwm_tree *const *kids, size_t n);
    \\duckwm_tree *duckwm_tree_windows(duckwm_arrange *ar, duckwm_axis axis, const uint32_t *ids, size_t n);
    \\void duckwm_tree_ratios(duckwm_arrange *ar, duckwm_tree *t, const double *ratios, size_t n);
    \\void duckwm_tree_key(duckwm_tree *t, uint32_t key); /* instead of the depth-first one */
    \\
    \\/* The layout (NULL: nothing), with resized ratios kept while the shape holds;
    \\ * an empty row is nothing, a row of one is that one. A mapped window gets focus. */
    \\duckwm_status duckwm_arrange_tree(duckwm_arrange *ar, const duckwm_tree *t);
    \\duckwm_status duckwm_arrange_keep_ids(duckwm_arrange *ar, const uint32_t *ids, size_t n);
    \\duckwm_reply *duckwm_arrange_reply(duckwm_arrange *ar); /* for anything else */
    \\
    \\/* ---- for good ---- */
    \\
    \\/* Connect, run setup, serve; when duckwm goes away, wait for it and do it all
    \\ * again. A setup that fails is retried with a growing delay. Never returns. */
    \\typedef duckwm_status (*duckwm_setup_fn)(void *userdata, duckwm_client *c);
    \\void duckwm_forever(duckwm_setup_fn setup, void *userdata);
    \\
    \\
;

const c_epilogue =
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#endif /* DUCKWM_H */
    \\
;

const z_prologue =
    \\// Generated by `zig build c` from duckwm's protocol.zig. Do not edit.
    \\// The C API's types (include/duckwm.h) as Zig extern declarations.
    \\
    \\
;

// ---- a function per command ----
/// One parameter of a command's function, from a field of its payload,
/// after sep ("" for the first, ", " for the rest).
fn emit_param(o: *Out, comptime F: type, comptime f: []const u8, comptime sep: []const u8) !void {
    const name = comptime c_ident(f);
    switch (@typeInfo(F)) {
        .optional => |opt| {
            const O = opt.child;
            if (comptime is_string(O)) {
                try o.c(sep ++ "const char *{s}", .{name});
            } else if (comptime is_list(O)) {
                try o.c(sep ++ "{s}{s}, size_t {s}_len", .{ c_many(@typeInfo(O).pointer.child), name, name });
            } else try o.c(sep ++ "const {s} *{s}", .{ c_type(O), name }); // NULL: absent
        },
        .pointer => |p| if (comptime is_string(F)) {
            try o.c(sep ++ "const char *{s}", .{name});
        } else try o.c(sep ++ "{s}{s}, size_t {s}_len", .{ c_many(p.child), name, name }),
        else => if (F == protocol.Callback) {
            try o.c(sep ++ "uint64_t {s}", .{name}); // what duckwm_register returned
        } else try o.c(sep ++ "{s} {s}", .{ c_type(F), name }),
    }
}

/// The same parameter passed on: a list is two arguments.
fn emit_arg(o: *Out, comptime F: type, comptime f: []const u8, comptime sep: []const u8) !void {
    const name = comptime c_ident(f);
    const O = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
    if (comptime is_list(O)) try o.c(sep ++ "{s}, {s}_len", .{ name, name }) else try o.c(sep ++ "{s}", .{name});
}

/// The statement setting that field in the command.
fn emit_init(o: *Out, comptime F: type, comptime cmd: []const u8, comptime f: []const u8) !void {
    const name = comptime c_ident(f);
    switch (@typeInfo(F)) {
        .optional => |opt| {
            const O = opt.child;
            if (comptime is_string(O) or is_compound(O)) {
                try o.c("    cmd.{s}.{s} = {s};\n", .{ cmd, name, name });
            } else if (comptime is_list(O)) {
                try o.c("    cmd.{s}.{s} = {s};\n    cmd.{s}.{s}_len = {s}_len;\n", .{ cmd, name, name, cmd, name, name });
            } else {
                try o.c("    cmd.{s}.has_{s} = {s} != NULL;\n", .{ cmd, name, name });
                try o.c("    if ({s}) cmd.{s}.{s} = *{s};\n", .{ name, cmd, name, name });
            }
        },
        .pointer => if (comptime is_string(F)) {
            try o.c("    cmd.{s}.{s} = {s};\n", .{ cmd, name, name });
        } else try o.c("    cmd.{s}.{s} = {s};\n    cmd.{s}.{s}_len = {s}_len;\n", .{ cmd, name, name, cmd, name, name }),
        else => if (F == protocol.Callback) {
            try o.c("    cmd.{s}.{s}.id = {s};\n", .{ cmd, name, name });
        } else try o.c("    cmd.{s}.{s} = {s};\n", .{ cmd, name, name }),
    }
}

/// duckwm_cmd_<name>(...), the command as a value for a batch, and
/// duckwm_<name>(c, ..., out), running it on its own. Plain assignments
/// rather than designated initializers, so the header is C++ as well.
fn emit_command_fns(o: *Out) !void {
    @setEvalBranchQuota(10_000_000);
    try o.c(
        \\/* ---- a function per command ----
        \\ *
        \\ * duckwm_cmd_<name>(...) is the command as a value, for a batch with
        \\ * duckwm_run. duckwm_<name>(c, ..., out) runs it on its own; out gets its
        \\ * one result, or pass NULL to drop it. Optional arguments are pointers
        \\ * (NULL: absent); callbacks are the ids duckwm_register returns.
        \\ */
        \\
        \\
    , .{});
    const u = @typeInfo(Command).@"union";
    inline for (u.field_names, u.field_types) |f, P| {
        const fields = switch (@typeInfo(P)) {
            .void => .{ .names = &[_][]const u8{}, .types = &[_]type{} },
            .@"struct" => |st| .{ .names = st.field_names, .types = st.field_types },
            else => @compileError("command " ++ f ++ ": its payload isn't a struct"),
        };
        const name = comptime c_ident(f);

        // duckwm_cmd_<name>: fill a zeroed command.
        try o.c("static inline duckwm_command duckwm_cmd_{s}(", .{name});
        if (fields.names.len == 0) try o.c("void", .{});
        inline for (fields.names, fields.types, 0..) |pf, PF, i| try emit_param(o, PF, pf, if (i == 0) "" else ", ");
        try o.c(") {{\n    duckwm_command cmd;\n    memset(&cmd, 0, sizeof cmd);\n", .{});
        try o.c("    cmd.kind = DUCKWM_COMMAND_{s};\n", .{comptime screaming(f)});
        inline for (fields.names, fields.types) |pf, PF| try emit_init(o, PF, name, pf);
        try o.c("    return cmd;\n}}\n", .{});

        // duckwm_<name>: the same arguments after c, then out.
        try o.c("static inline duckwm_status duckwm_{s}(duckwm_client *c", .{name});
        inline for (fields.names, fields.types) |pf, PF| try emit_param(o, PF, pf, ", ");
        try o.c(", duckwm_results *out) {{\n    duckwm_command cmd = duckwm_cmd_{s}(", .{name});
        inline for (fields.names, fields.types, 0..) |pf, PF, i| try emit_arg(o, PF, pf, if (i == 0) "" else ", ");
        try o.c(");\n    return duckwm_run(c, &cmd, 1, out);\n}}\n\n", .{});
    }
}

pub fn generate(a: std.mem.Allocator) !struct { []u8, []u8 } {
    @setEvalBranchQuota(10_000_000);
    var o: Out = .{ .a = a };
    try o.h.appendSlice(a, c_prologue);
    try o.z.appendSlice(a, z_prologue);

    // Every struct by name first, so pointers can point anywhere.
    try o.c("/* ---- types ---- */\n\n", .{});
    inline for (all_types) |n| {
        if (comptime is_compound(n.T)) try o.c("typedef struct duckwm_{s} duckwm_{s};\n", .{ n.name, n.name });
    }
    try o.c("\n", .{});
    inline for (all_types) |n| switch (@typeInfo(n.T)) {
        .@"enum" => try emit_enum(&o, n),
        .@"union" => try emit_kind(&o, n),
        else => {},
    };
    inline for (definition_order) |n| switch (@typeInfo(n.T)) {
        .@"struct" => try emit_struct(&o, n),
        .@"union" => try emit_union(&o, n),
        else => unreachable,
    };
    try o.h.appendSlice(a, c_api);
    try emit_command_fns(&o);
    try o.h.appendSlice(a, c_epilogue);
    return .{ o.h.items, o.z.items };
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    const h, const z = try generate(a);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = h });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = z });
}
