//! A client library for duckwm's socket, in Zig.

const std = @import("std");

pub const protocol = @import("protocol");
pub const core = @import("duckwm_client");
const client = @import("client.zig");
const keys = @import("keys.zig");
pub const value = @import("value.zig");
pub const geometry = @import("geometry.zig");
pub const arrange = @import("arrange.zig");
pub const tree = @import("tree.zig");
pub const layouts = @import("layouts.zig");
const forever_mod = @import("forever.zig");

pub const Command = protocol.Command;
pub const Value = protocol.Value;
pub const CallArgs = protocol.CallArgs;
pub const Callback = protocol.Callback;
pub const Mods = keys.Mods;
pub const KeyCombo = keys.KeyCombo;
pub const Rect = geometry.Rect;
pub const Arranger = arrange.Arranger;
pub const Snapshot = arrange.Snapshot;
pub const Client = client.Client;
pub const Handler = client.Handler;
pub const Reply = client.Reply;
pub const Error = client.Error;
pub const Platform = client.Platform;
pub const Workspace = client.Workspace;
pub const WorkspaceState = client.WorkspaceState;
pub const Within = client.Within;

pub const socket_path = core.socket_path;
pub const forever = forever_mod.forever;
pub const forever_at = forever_mod.forever_at;

test {
    std.testing.refAllDecls(@This());
    _ = keys;
    _ = value;
    _ = geometry;
    _ = arrange;
    _ = tree;
    _ = layouts;
    _ = client;
}
