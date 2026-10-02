/* A minimal Wayland client for testing ishwl's drag and drop without GTK.
 *   dnd-test source MIME TEXT   starts a drag on the first button press, serves TEXT
 *   dnd-test target             accepts the first offered type and prints what it gets
 * Every protocol event is printed on stdout, one per line. Build in the guest:
 *   wayland-scanner client-header $XDG xdg-shell-client.h
 *   wayland-scanner private-code $XDG xdg-shell.c
 *   cc -o dnd-test tools/dnd-test.c xdg-shell.c -I. $(pkg-config --cflags --libs wayland-client) */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_data_device_manager *ddm;
static struct wl_data_device *device;
static struct wl_surface *surface;
static struct wl_data_offer *current_offer;
static char offered[8][128];
static int offered_count;
static const char *mode, *drag_mime, *drag_text;
static bool done;

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

/* ---- source ---- */

static void source_target(void *data, struct wl_data_source *s, const char *mime) { say("source target %s", mime ? mime : "-"); }
static void source_send(void *data, struct wl_data_source *s, const char *mime, int32_t fd) {
    say("source send %s", mime);
    if (write(fd, drag_text, strlen(drag_text)) < 0) say("source write failed");
    close(fd);
}
static void source_cancelled(void *data, struct wl_data_source *s) { say("source cancelled"); wl_data_source_destroy(s); }
static void source_drop_performed(void *data, struct wl_data_source *s) { say("source drop_performed"); }
static void source_finished(void *data, struct wl_data_source *s) { say("source finished"); wl_data_source_destroy(s); }
static void source_action(void *data, struct wl_data_source *s, uint32_t action) { say("source action %u", action); }
static const struct wl_data_source_listener source_listener = {
    source_target, source_send, source_cancelled, source_drop_performed, source_finished, source_action,
};

/* ---- offers (target) ---- */

static void offer_offer(void *data, struct wl_data_offer *o, const char *mime) {
    if (offered_count < 8) snprintf(offered[offered_count++], sizeof(offered[0]), "%s", mime);
}
static void offer_source_actions(void *data, struct wl_data_offer *o, uint32_t actions) { say("offer source_actions %u", actions); }
static void offer_action(void *data, struct wl_data_offer *o, uint32_t action) { say("offer action %u", action); }
static const struct wl_data_offer_listener offer_listener = { offer_offer, offer_source_actions, offer_action };

static void device_data_offer(void *data, struct wl_data_device *d, struct wl_data_offer *o) {
    offered_count = 0;
    wl_data_offer_add_listener(o, &offer_listener, NULL);
}
static void device_enter(void *data, struct wl_data_device *d, uint32_t serial, struct wl_surface *s,
                         wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *o) {
    current_offer = o;
    say("target enter %.0f %.0f types %d first %s", wl_fixed_to_double(x), wl_fixed_to_double(y),
        offered_count, offered_count ? offered[0] : "-");
    if (o && offered_count) {
        wl_data_offer_accept(o, serial, offered[0]);
        wl_data_offer_set_actions(o, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE,
                                  WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
    }
}
static void device_leave(void *data, struct wl_data_device *d) { say("target leave"); current_offer = NULL; }
static void device_motion(void *data, struct wl_data_device *d, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    say("target motion %.0f %.0f", wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void device_drop(void *data, struct wl_data_device *d) {
    say("target drop");
    if (!current_offer || !offered_count) return;
    int fds[2];
    if (pipe(fds) < 0) return;
    wl_data_offer_receive(current_offer, offered[0], fds[1]);
    close(fds[1]);
    wl_display_roundtrip(data);
    char buf[4096];
    ssize_t n = read(fds[0], buf, sizeof(buf) - 1);
    close(fds[0]);
    buf[n > 0 ? n : 0] = '\0';
    say("target data %s: %s", offered[0], buf);
    wl_data_offer_finish(current_offer);
    wl_data_offer_destroy(current_offer);
    current_offer = NULL;
    done = true;
}
static void device_selection(void *data, struct wl_data_device *d, struct wl_data_offer *o) {}
static const struct wl_data_device_listener device_listener = {
    device_data_offer, device_enter, device_leave, device_motion, device_drop, device_selection,
};

/* ---- pointer ---- */

static void pointer_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) { say("pointer enter"); }
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) { say("pointer leave"); }
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state) {
    say("pointer button %u %u", button, state);
    if (strcmp(mode, "source") != 0 || state != WL_POINTER_BUTTON_STATE_PRESSED) return;
    struct wl_data_source *source = wl_data_device_manager_create_data_source(ddm);
    wl_data_source_add_listener(source, &source_listener, NULL);
    wl_data_source_offer(source, drag_mime);
    wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
    wl_data_device_start_drag(device, source, surface, NULL, serial);
    say("source start_drag");
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) {}
static void pointer_frame(void *d, struct wl_pointer *p) {}
static void pointer_axis_source(void *d, struct wl_pointer *p, uint32_t s) {}
static void pointer_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) {}
static void pointer_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) {}
static const struct wl_pointer_listener pointer_listener = {
    pointer_enter, pointer_leave, pointer_motion, pointer_button, pointer_axis,
    pointer_frame, pointer_axis_source, pointer_axis_stop, pointer_axis_discrete,
};

/* ---- shell ---- */

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t serial) { xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void attach_buffer(void) {
    int w = 200, h = 100, stride = w * 4, size = stride * h;
    char name[] = "/dev/shm/dnd-test-XXXXXX";
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
    xdg_surface_ack_configure(x, serial);
    static bool attached;
    if (!attached) { attached = true; attach_buffer(); } else wl_surface_commit(surface);
}
static const struct xdg_surface_listener xdg_listener = { xdg_configure };

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    if (!strcmp(iface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "xdg_wm_base")) wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "wl_seat")) seat = wl_registry_bind(r, name, &wl_seat_interface, 5);
    else if (!strcmp(iface, "wl_data_device_manager")) ddm = wl_registry_bind(r, name, &wl_data_device_manager_interface, 3);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener registry_listener = { global, global_remove };

int main(int argc, char **argv) {
    mode = argc > 1 ? argv[1] : "target";
    drag_mime = argc > 2 ? argv[2] : "text/plain;charset=utf-8";
    drag_text = argc > 3 ? argv[3] : "hello from dnd-test";
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "no display\n"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base || !seat || !ddm) { fprintf(stderr, "missing globals\n"); return 1; }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    struct wl_pointer *pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    device = wl_data_device_manager_get_data_device(ddm, seat);
    wl_data_device_add_listener(device, &device_listener, display);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg, &xdg_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_set_title(toplevel, mode);
    wl_surface_commit(surface);
    say("%s ready", mode);
    while (!done && wl_display_dispatch(display) >= 0) {}
    wl_display_roundtrip(display);
    return 0;
}
