const std = @import("std");

/// A modifier bitmask: X's layout, which duckwm uses on both backends.
pub const Mods = packed struct(u32) {
    shift: bool = false,
    lock: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    super: bool = false,
    mod5: bool = false,
    _: u24 = 0,

    pub const none: Mods = .{};

    /// The order combos are written in: "super+ctrl+alt+shift+q".
    pub const order = [_][]const u8{ "super", "ctrl", "alt", "shift", "lock", "mod2", "mod3", "mod5" };

    pub fn bits(m: Mods) u32 {
        return @bitCast(m);
    }

    pub fn from_bits(b: u32) Mods {
        return @bitCast(b);
    }

    /// One modifier by name, any case; "control" is ctrl, "mod4" super, "mod1" alt.
    pub fn from_name(name: []const u8) ?Mods {
        var lower: [16]u8 = undefined;
        if (name.len > lower.len) return null;
        const n = std.ascii.lowerString(&lower, name);
        const aliases = [_]struct { []const u8, []const u8 }{ .{ "control", "ctrl" }, .{ "mod4", "super" }, .{ "mod1", "alt" } };
        const canon = for (aliases) |al| {
            if (std.mem.eql(u8, n, al[0])) break al[1];
        } else n;
        inline for (order) |field| {
            if (std.mem.eql(u8, canon, field)) {
                var m: Mods = .{};
                @field(m, field) = true;
                return m;
            }
        }
        return null;
    }

    pub fn with(a: Mods, b: Mods) Mods {
        return from_bits(a.bits() | b.bits());
    }
};

/// A bound key: modifiers plus a keysym name ("q", "Return").
pub const KeyCombo = struct {
    mods: Mods,
    key: []const u8,

    pub const ParseError = error{ MissingKey, UnknownModifier };

    /// "super+shift+q": the key is the last part, the rest are modifiers. The
    /// key points into s.
    pub fn parse(s: []const u8) ParseError!KeyCombo {
        const plus = std.mem.lastIndexOfScalar(u8, s, '+');
        const key = if (plus) |p| s[p + 1 ..] else s;
        if (key.len == 0) return error.MissingKey;
        var mods: Mods = .{};
        if (plus) |p| {
            var it = std.mem.tokenizeScalar(u8, s[0..p], '+');
            while (it.next()) |name| mods = mods.with(Mods.from_name(name) orelse return error.UnknownModifier);
        }
        return .{ .mods = mods, .key = key };
    }

    /// "super+shift+q", for {f}.
    pub fn format(c: KeyCombo, w: *std.Io.Writer) std.Io.Writer.Error!void {
        inline for (Mods.order) |field| {
            if (@field(c.mods, field)) try w.print("{s}+", .{field});
        }
        try w.writeAll(c.key);
    }
};

test "round trips" {
    const c = try KeyCombo.parse("shift+Super+q");
    try std.testing.expect(c.mods.super and c.mods.shift);
    try std.testing.expectEqual(@as(u32, 65), c.mods.bits());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("super+shift+q", try std.fmt.bufPrint(&buf, "{f}", .{c}));
    try std.testing.expectEqualStrings("Return", try std.fmt.bufPrint(&buf, "{f}", .{try KeyCombo.parse("Return")}));
}

test "rejects junk" {
    try std.testing.expectError(error.MissingKey, KeyCombo.parse("super+"));
    try std.testing.expectError(error.UnknownModifier, KeyCombo.parse("hyper+q"));
}
