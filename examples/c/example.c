/* duckwm from C: list the key bindings, bind super+u to kill the focused
 * window, lay workspaces out with an arranger written in C, and keep it all
 * up across duckwm restarts.
 *
 *     zig build examples && ./zig-out/bin/example-c
 *     cc example.c $(pkg-config --cflags --libs duckwm)
 */
#include <stdio.h>

#include "duckwm.h"

static void on_super_u(void *userdata, duckwm_client *c,
                       const duckwm_call_args *args, duckwm_reply *reply) {
  int *presses = userdata;
  (void)args;
  ++*presses;

  /* Runs inside the transaction the key press started. */
  duckwm_results res;
  if (duckwm_get_focused(c, &res) != DUCKWM_OK) {
    duckwm_reply_error(reply, duckwm_last_error(c));
    return;
  }
  if (res.values[0].kind == DUCKWM_VALUE_INTEGER)
    printf("press %d: killing %lld\n", *presses,
           (long long)res.values[0].integer);
  duckwm_results_free(&res);

  /* Copied: it doesn't have to outlive this call. */
  duckwm_reply_command(reply, duckwm_cmd_kill_client());
}

/* Every window side by side, a new one after the window that was focused;
 * the order is kept in duckwm between calls. Nothing here needs freeing. */
static void columns(void *userdata, duckwm_arrange *ar) {
  (void)userdata;
  size_t n;
  const uint32_t *order = duckwm_arrange_track(ar, &n);
  duckwm_arrange_tree(ar, duckwm_tree_windows(ar, DUCKWM_AXIS_H, order, n));
  duckwm_arrange_keep_ids(ar, order, n);
}

static int presses;
static duckwm_arranger *columns_arranger;

/* Run on every connection; what it sets up goes away with the connection. */
static duckwm_status setup(void *userdata, duckwm_client *c) {
  (void)userdata;
  printf("%s, startup: %d\n",
         duckwm_get_platform(c) == DUCKWM_PLATFORM_RIVER ? "river" : "x11",
         duckwm_startup(c));

  duckwm_results res;
  duckwm_status s = duckwm_get_keybinds(c, &res);
  if (s != DUCKWM_OK)
    return s;
  const duckwm_value *binds = &res.values[0];
  for (size_t i = 0; binds->kind == DUCKWM_VALUE_LIST && i < binds->list.len;
       i++) {
    const duckwm_value *mods = duckwm_value_get(&binds->list.items[i], "mods");
    const duckwm_value *key = duckwm_value_get(&binds->list.items[i], "key");
    char combo[64];
    duckwm_format_combo((uint32_t)mods->integer, key->str, combo, sizeof combo);
    printf("  %s\n", combo);
  }
  duckwm_results_free(&res);

  if ((s = duckwm_bind_key(c, "super+u", on_super_u, &presses)) != DUCKWM_OK)
    return s;
  return duckwm_use_default_arranger(c,
                                     columns_arranger); /* or duckwm_tile() */
}

int main(void) {
  columns_arranger = duckwm_arranger_new("columns", columns, NULL);
  /* Or by hand: duckwm_connect, then duckwm_serve, or poll duckwm_fd and
   * call duckwm_dispatch from an event loop of your own. */
  duckwm_forever(setup, NULL);
}
