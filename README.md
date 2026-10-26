# libduckwm

Zig and C client libraries for [duckwm](https://github.com/DuckTapeMan35/duckwm):
the same thing as duckwm_rs and duckwm_py, written once in Zig and exported
to C as `libduckwm`.

- **Commands** are values: `c.run_one(arena, .{ .focus = .{ .id = 3 } })` in
  Zig, `duckwm_focus(c, 3, NULL)` or `duckwm_cmd_focus(3)` in C. Several run
  as one transaction with `run` / `duckwm_run`.
- **Keys** by name: `c.bind(arena, "super+shift+u", handler)`,
  `duckwm_bind_key(c, "super+shift+u", handler, userdata)`.
- **Arrangers**: `layouts.tile` and `layouts.fair`, or your own, built from
  rows and columns (`tree`), rectangles (`geometry`) and `arrange.track`.
- **Callbacks** run inside the transaction that called them: their requests
  are part of it, and their reply finishes it.
- **`forever`** keeps a config up across duckwm restarts.

Blocking and single-threaded: callbacks run inside `run`, `serve` and
`dispatch`. For an event loop of your own, poll `fd()` / `duckwm_fd` and call
`dispatch`.

## Zig

```sh
zig fetch --save git+https://github.com/DuckTapeMan35/libduckwm
```

```zig
// build.zig
const duckwm = b.dependency("duckwm", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("duckwm", duckwm.module("duckwm"));
```

```zig
const duckwm = @import("duckwm");

fn on_super_u(c: *duckwm.Client, _: duckwm.CallArgs, arena: std.mem.Allocator) anyerror!duckwm.Reply {
    _ = try c.run_one(arena, .get_focused); // runs inside the key press
    return .{ .commands = try arena.dupe(duckwm.Command, &.{.kill_client}) };
}

fn setup(_: void, c: *duckwm.Client) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    try c.bind(arena.allocator(), "super+u", .func_of(on_super_u));
    try c.default_arranger(arena.allocator(), duckwm.layouts.tile);
}

pub fn main() void {
    duckwm.forever(std.heap.c_allocator, {}, setup);
}
```

The whole example is `examples/zig/example.zig`.

## C

`zig build` installs `lib/libduckwm.a`, `lib/libduckwm.so`,
`include/duckwm.h` and `lib/pkgconfig/duckwm.pc`; with Nix,
`packages.libduckwm`. One header has everything:

```sh
cc config.c $(pkg-config --cflags --libs duckwm)
```

See `examples/c/example.c`: a key binding, an arranger written in C, and
`duckwm_forever`. Memory a callback or arranger is handed lives for the call;
what it hands back is copied, so it can come from the stack.

## Layout

- `src/upstream/`: duckwm's own files (protocol, encoding, the core client),
  copied by `scripts/sync`. Don't edit them here.
- `src/duckwm.zig`: the library's root; `client.zig`, `keys.zig`,
  `value.zig`, `geometry.zig`, `arrange.zig`, `tree.zig`, `layouts.zig`,
  `forever.zig`.
- `src/c.zig`: the C API. `include/duckwm.h` and `src/c_types.zig` are
  generated from the protocol by `src/gen_c.zig` (`zig build c`).

When duckwm's copies change, its notify workflow sends a dispatch here, and
`.github/workflows/sync.yml` syncs, regenerates, tests and commits. By hand:

```sh
DUCKWM_SRC=../duckwm ./scripts/sync
zig build test examples
```
