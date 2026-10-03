/* A minimal Wayland client for testing ishwl's keyboard layouts without a toolkit.
 *   keymap-test [SECONDS]
 * Maps one toplevel and, like a real client, builds an xkb_state (and a compose state
 * for dead keys) from every wl_keyboard.keymap it gets. Prints one line per keymap:
 *   keymap N "LAYOUT NAME" layouts=1 Y=y Z=z [=ü -=ß Q+R=@ L+R=@ ;=ö GRAVE=^ ...
 * (evdev keys alone, +R with Right Alt held, which is AltGr in most layouts, +L with
 * Left Alt held) and, for
 * every key press, the text typed so far after compose:
 *   text ü@ß
 * With TEXTINPUT=1 it also enables a zwp_text_input_v3 while focused, as Chromium, GTK
 * and Qt do, and appends commit_string text to the same line (ishwl then delivers keys
 * and text in order, one at a time).
 * Exits after SECONDS (default 20) with no events. Build in the guest:
 *   wayland-scanner client-header $XDG xdg-shell-client.h
 *   wayland-scanner private-code $XDG xdg-shell.c
 *   (the same two for text-input-unstable-v3)
 *   cc -o keymap-test tools/keymap-test.c xdg-shell.c text-input-unstable-v3.c -I. \
 *      $(pkg-config --cflags --libs wayland-client xkbcommon) */
#define _GNU_SOURCE
#include <linux/input-event-codes.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <locale.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include "text-input-unstable-v3-client.h"
#include "xdg-shell-client.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_surface *surface;
static struct xkb_context *ctx;
static struct xkb_keymap *keymap;
static struct xkb_state *state;
static struct xkb_compose_state *compose;
static int keymaps;
static char typed[2048];
static struct zwp_text_input_manager_v3 *ti_manager;
static struct zwp_text_input_v3 *text_input;
static bool use_text_input;

static const struct probe {
    const char *name;
    uint32_t key;
    uint32_t hold;  /* a modifier key held for the probe, 0 for none */
} probes[] = {
    {"Y", KEY_Y}, {"Z", KEY_Z}, {"Q", KEY_Q}, {"A", KEY_A}, {"[", KEY_LEFTBRACE}, {"-", KEY_MINUS},
    {";", KEY_SEMICOLON}, {"'", KEY_APOSTROPHE}, {"GRAVE", KEY_GRAVE}, {"LSGT", KEY_102ND},
    {"2", KEY_2}, {"Q+R", KEY_Q, KEY_RIGHTALT}, {"L+R", KEY_L, KEY_RIGHTALT},
    {"E+R", KEY_E, KEY_RIGHTALT}, {"5+R", KEY_5, KEY_RIGHTALT}, {"L+L", KEY_L, KEY_LEFTALT},
};

static void append_utf8(char *out, size_t size, uint32_t cp) {
    char buf[8] = {0};
    if (cp == 0) return;
    if (cp < 0x80) buf[0] = (char) cp;
    else if (cp < 0x800) { buf[0] = (char) (0xc0 | cp >> 6); buf[1] = (char) (0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) { buf[0] = (char) (0xe0 | cp >> 12); buf[1] = (char) (0x80 | (cp >> 6 & 0x3f)); buf[2] = (char) (0x80 | (cp & 0x3f)); }
    else { buf[0] = (char) (0xf0 | cp >> 18); buf[1] = (char) (0x80 | (cp >> 12 & 0x3f)); buf[2] = (char) (0x80 | (cp >> 6 & 0x3f)); buf[3] = (char) (0x80 | (cp & 0x3f)); }
    strncat(out, buf, size - strlen(out) - 1);
}

static void print_probes(void) {
    char line[1024];
    snprintf(line, sizeof(line), "keymap %d \"%s\" layouts=%u", keymaps, xkb_keymap_layout_get_name(keymap, 0),
             xkb_keymap_num_layouts(keymap));
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        struct xkb_state *scratch = xkb_state_new(keymap);
        if (probes[i].hold)
            xkb_state_update_key(scratch, probes[i].hold + 8, XKB_KEY_DOWN);
        char text[16] = "";
        uint32_t cp = xkb_state_key_get_utf32(scratch, probes[i].key + 8);
        if (cp) append_utf8(text, sizeof(text), cp);
        else xkb_keysym_get_name(xkb_state_key_get_one_sym(scratch, probes[i].key + 8), text, sizeof(text));
        size_t len = strlen(line);
        snprintf(line + len, sizeof(line) - len, " %s=%s", probes[i].name, text);
        xkb_state_unref(scratch);
    }
    printf("%s\n", line);
    fflush(stdout);
}

static void print_typed(void) {
    printf("text %s\n", typed);
    fflush(stdout);
}

/* ---- text input: commit after enter and after every done, as toolkits do ---- */
static void ti_enter(void *d, struct zwp_text_input_v3 *ti, struct wl_surface *s) {
    zwp_text_input_v3_enable(ti);
    zwp_text_input_v3_set_content_type(ti, 0, 0);
    zwp_text_input_v3_commit(ti);
    printf("textinput enabled\n");
    fflush(stdout);
}
static void ti_leave(void *d, struct zwp_text_input_v3 *ti, struct wl_surface *s) {}
static void ti_preedit(void *d, struct zwp_text_input_v3 *ti, const char *text, int32_t b, int32_t e) {}
static void ti_commit_string(void *d, struct zwp_text_input_v3 *ti, const char *text) {
    if (!text) return;
    strncat(typed, text, sizeof(typed) - strlen(typed) - 1);
    print_typed();
}
static void ti_delete(void *d, struct zwp_text_input_v3 *ti, uint32_t before, uint32_t after) {}
static void ti_done(void *d, struct zwp_text_input_v3 *ti, uint32_t serial) {
    zwp_text_input_v3_commit(ti);
}
static const struct zwp_text_input_v3_listener ti_listener = {
    ti_enter, ti_leave, ti_preedit, ti_commit_string, ti_delete, ti_done,
};

static void kb_keymap(void *d, struct wl_keyboard *kb, uint32_t format, int32_t fd, uint32_t size) {
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { printf("keymap mmap failed\n"); return; }
    struct xkb_keymap *next = xkb_keymap_new_from_string(ctx, map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (!next) { printf("keymap compile failed\n"); fflush(stdout); return; }
    xkb_state_unref(state);
    xkb_keymap_unref(keymap);
    keymap = next;
    state = xkb_state_new(keymap);
    keymaps++;
    print_probes();
}

static void kb_enter(void *d, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *s, struct wl_array *keys) {
    printf("keyboard enter\n");
    fflush(stdout);
}
static void kb_leave(void *d, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *s) {}

static void kb_key(void *d, struct wl_keyboard *kb, uint32_t serial, uint32_t time, uint32_t key, uint32_t pressed) {
    if (!state || pressed != WL_KEYBOARD_KEY_STATE_PRESSED) return;
    xkb_keysym_t sym = xkb_state_key_get_one_sym(state, key + 8);
    uint32_t cp = 0;
    if (compose && xkb_compose_state_feed(compose, sym) == XKB_COMPOSE_FEED_ACCEPTED) {
        switch (xkb_compose_state_get_status(compose)) {
        case XKB_COMPOSE_COMPOSING: return;
        case XKB_COMPOSE_COMPOSED:
            cp = xkb_keysym_to_utf32(xkb_compose_state_get_one_sym(compose));
            xkb_compose_state_reset(compose);
            break;
        case XKB_COMPOSE_CANCELLED: xkb_compose_state_reset(compose); return;
        case XKB_COMPOSE_NOTHING: cp = xkb_state_key_get_utf32(state, key + 8); break;
        }
    } else {
        cp = xkb_state_key_get_utf32(state, key + 8);
    }
    if (cp < 0x20 || cp == 0x7f) return;
    append_utf8(typed, sizeof(typed), cp);
    print_typed();
    /* An edit is followed by the text input's state, which tells ishwl the key landed. */
    if (text_input) zwp_text_input_v3_commit(text_input);
}

static void kb_modifiers(void *d, struct wl_keyboard *kb, uint32_t serial, uint32_t dep, uint32_t lat,
                         uint32_t lock, uint32_t group) {
    if (state) xkb_state_update_mask(state, dep, lat, lock, 0, 0, group);
}
static void kb_repeat(void *d, struct wl_keyboard *kb, int32_t rate, int32_t delay) {}
static const struct wl_keyboard_listener kb_listener = {
    kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat,
};

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t serial) { xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void attach_buffer(void) {
    int w = 64, h = 64, stride = w * 4, size = stride * h;
    char name[] = "/dev/shm/keymap-test-XXXXXX";
    int fd = mkstemp(name);
    unlink(name);
    if (fd < 0 || ftruncate(fd, size) < 0) exit(1);
    void *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    memset(pixels, 0x80, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, w, h);
    wl_surface_commit(surface);
}

static void xdg_configure(void *d, struct xdg_surface *x, uint32_t serial) {
    static bool attached;
    xdg_surface_ack_configure(x, serial);
    if (!attached) { attached = true; attach_buffer(); } else wl_surface_commit(surface);
}
static const struct xdg_surface_listener xdg_listener = { xdg_configure };

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    if (!strcmp(iface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base")) wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wl_seat")) seat = wl_registry_bind(r, name, &wl_seat_interface, 5);
    else if (!strcmp(iface, "zwp_text_input_manager_v3"))
        ti_manager = wl_registry_bind(r, name, &zwp_text_input_manager_v3_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener registry_listener = { global, global_remove };

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 20;
    use_text_input = getenv("TEXTINPUT") && strcmp(getenv("TEXTINPUT"), "1") == 0;
    setlocale(LC_ALL, "");
    ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    const char *locale = getenv("LC_ALL");
    if (!locale || !*locale) locale = getenv("LANG");
    if (!locale || !*locale) locale = "C";
    struct xkb_compose_table *table = xkb_compose_table_new_from_locale(ctx, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
    printf("compose %s: %s\n", locale, table ? "ok" : "missing");
    if (table) compose = xkb_compose_state_new(table, XKB_COMPOSE_STATE_NO_FLAGS);

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "no display\n"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base || !seat) { fprintf(stderr, "missing globals\n"); return 1; }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    struct wl_keyboard *kb = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(kb, &kb_listener, NULL);
    if (use_text_input && ti_manager) {
        text_input = zwp_text_input_manager_v3_get_text_input(ti_manager, seat);
        zwp_text_input_v3_add_listener(text_input, &ti_listener, NULL);
    }
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg, &xdg_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_set_title(toplevel, "keymap-test");
    wl_surface_commit(surface);
    printf("ready\n");
    fflush(stdout);

    struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
    for (;;) {
        while (wl_display_prepare_read(display) != 0)
            wl_display_dispatch_pending(display);
        wl_display_flush(display);
        if (poll(&pfd, 1, seconds * 1000) <= 0) {
            wl_display_cancel_read(display);
            break;
        }
        if (wl_display_read_events(display) < 0 || wl_display_dispatch_pending(display) < 0)
            break;
    }
    printf("done\n");
    return 0;
}
