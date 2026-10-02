/* The clipboard (wl_data_device selection), text only.
 *
 * ishwl owns the selection itself: when an app copies, its text is read out at
 * once and kept here, then offered to whichever app has keyboard focus and to
 * the host (UIPasteboard). Text from the host arrives the same way. Owning the
 * text, instead of forwarding between clients, keeps a copy alive after the
 * source app quits, as on other desktops. Drag and drop is in dnd.c. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ishwl.h"

#define MAX_SELECTION (4 << 20)

static const char *const text_mimes[] = {
    "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING",
};

static bool is_text_mime(const char *mime) {
    for (size_t i = 0; i < sizeof(text_mimes) / sizeof(*text_mimes); i++)
        if (strcmp(mime, text_mimes[i]) == 0) return true;
    return false;
}

static void destroy_request(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void resource_unlink(struct wl_resource *resource) {
    wl_list_remove(wl_resource_get_link(resource));
}

/* ---- writing the selection into a pipe an app gave us ---- */

struct pipe_writer {
    struct wl_event_source *source;
    int fd;
    char *data;
    size_t len, off;
};

static void writer_finish(struct pipe_writer *w) {
    if (w->source) wl_event_source_remove(w->source);
    close(w->fd);
    free(w->data);
    free(w);
}

static int writer_writable(int fd, uint32_t mask, void *data) {
    struct pipe_writer *w = data;
    while (w->off < w->len) {
        ssize_t n = write(fd, w->data + w->off, w->len - w->off);
        if (n < 0 && errno == EAGAIN) return 0;
        if (n <= 0) break;
        w->off += n;
    }
    writer_finish(w);
    return 0;
}

static void write_selection(struct server *s, int fd) {
    struct pipe_writer *w = calloc(1, sizeof(*w));
    if (!w || !s->selection) {
        free(w);
        close(fd);
        return;
    }
    w->fd = fd;
    w->len = s->selection_len;
    w->data = malloc(w->len ? w->len : 1);
    if (!w->data) {
        free(w);
        close(fd);
        return;
    }
    memcpy(w->data, s->selection, w->len);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    w->source = wl_event_loop_add_fd(s->loop, fd, WL_EVENT_WRITABLE, writer_writable, w);
    if (!w->source) writer_finish(w);
}

/* ---- offers ---- */

static void offer_accept(struct wl_client *client, struct wl_resource *resource, uint32_t serial, const char *mime) {
}

static void offer_receive(struct wl_client *client, struct wl_resource *resource, const char *mime, int32_t fd) {
    struct server *s = wl_resource_get_user_data(resource);
    if (!s || !is_text_mime(mime)) {
        close(fd);
        return;
    }
    write_selection(s, fd);
}

static void offer_finish(struct wl_client *client, struct wl_resource *resource) {
}

static void offer_set_actions(struct wl_client *client, struct wl_resource *resource,
                              uint32_t actions, uint32_t preferred) {
}

static const struct wl_data_offer_interface offer_impl = {
    .accept = offer_accept,
    .receive = offer_receive,
    .destroy = destroy_request,
    .finish = offer_finish,
    .set_actions = offer_set_actions,
};

static void offer_to_device(struct server *s, struct wl_resource *device) {
    if (!s->selection) {
        wl_data_device_send_selection(device, NULL);
        return;
    }
    struct wl_resource *offer = wl_resource_create(wl_resource_get_client(device), &wl_data_offer_interface,
                                                   wl_resource_get_version(device), 0);
    if (!offer) return;
    wl_resource_set_implementation(offer, &offer_impl, s, NULL);
    wl_data_device_send_data_offer(device, offer);
    for (size_t i = 0; i < sizeof(text_mimes) / sizeof(*text_mimes); i++)
        wl_data_offer_send_offer(offer, text_mimes[i]);
    wl_data_device_send_selection(device, offer);
}

/* Wayland only shows the selection to the app with keyboard focus. */
void clipboard_focus_changed(struct server *s, struct wl_client *client) {
    if (!client) return;
    struct wl_resource *device;
    wl_resource_for_each(device, &s->data_devices)
        if (wl_resource_get_client(device) == client)
            offer_to_device(s, device);
}

static void selection_changed(struct server *s, bool from_host) {
    if (s->keyboard_focus)
        clipboard_focus_changed(s, wl_resource_get_client(s->keyboard_focus->resource));
    if (from_host) return;
    char path[256], tmp[260];
    snprintf(path, sizeof(path), "%s/clipboard-out", s->runtime_dir);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return;
    bool ok = fwrite(s->selection, 1, s->selection_len, f) == s->selection_len;
    if (fclose(f) == 0 && ok && rename(tmp, path) == 0)
        bridge_send(s, "clipboard %zu\n", s->selection_len);
}

static void replace_selection_source(struct server *s, struct wl_resource *source);

static void set_selection(struct server *s, char *text, size_t len, bool from_host) {
    free(s->selection);
    s->selection = text;
    s->selection_len = len;
    log_msg(s, "selection: %zu bytes from %s", len, from_host ? "host" : "app");
    selection_changed(s, from_host);
}

void clipboard_set_from_host(struct server *s) {
    char path[256];
    snprintf(path, sizeof(path), "%s/clipboard-in", s->runtime_dir);
    FILE *f = fopen(path, "rb");
    if (!f) return;
    char *text = malloc(MAX_SELECTION);
    size_t len = text ? fread(text, 1, MAX_SELECTION, f) : 0;
    fclose(f);
    if (!text) return;
    replace_selection_source(s, NULL);
    set_selection(s, text, len, true);
}

/* ---- reading a new selection from the app that copied ---- */

struct pipe_reader {
    struct server *server;
    struct wl_event_source *source;
    int fd;
    char *data;
    size_t len, cap;
};

static int reader_readable(int fd, uint32_t mask, void *data) {
    struct pipe_reader *r = data;
    for (;;) {
        if (r->len == r->cap) {
            size_t cap = r->cap ? r->cap * 2 : 4096;
            char *grown = cap <= MAX_SELECTION ? realloc(r->data, cap) : NULL;
            if (!grown) break;
            r->data = grown;
            r->cap = cap;
        }
        ssize_t n = read(fd, r->data + r->len, r->cap - r->len);
        if (n < 0 && errno == EAGAIN) return 0;
        if (n <= 0) break;
        r->len += n;
    }
    wl_event_source_remove(r->source);
    close(fd);
    set_selection(r->server, r->data, r->len, false);
    free(r);
    return 0;
}

/* ---- data sources ---- */

/* The app that copied last keeps its source until something replaces it, which
 * is when the protocol says to cancel it. */
static void replace_selection_source(struct server *s, struct wl_resource *source) {
    if (s->selection_source && s->selection_source != source)
        wl_data_source_send_cancelled(s->selection_source);
    s->selection_source = source;
}

struct data_source {
    struct wl_resource *resource;
    struct server *server;
    int mime; /* index into text_mimes of the best type offered, or -1 */
};

static void source_offer(struct wl_client *client, struct wl_resource *resource, const char *mime) {
    struct data_source *source = wl_resource_get_user_data(resource);
    dnd_source_offer(resource, mime);
    for (int i = 0; i < (int) (sizeof(text_mimes) / sizeof(*text_mimes)); i++) {
        if (strcmp(mime, text_mimes[i]) != 0) continue;
        if (source->mime < 0 || i < source->mime)
            source->mime = i;
        return;
    }
}

static void source_set_actions(struct wl_client *client, struct wl_resource *resource, uint32_t actions) {
    dnd_source_actions(resource, actions);
}

static const struct wl_data_source_interface source_impl = {
    .offer = source_offer,
    .destroy = destroy_request,
    .set_actions = source_set_actions,
};

static void source_resource_destroy(struct wl_resource *resource) {
    struct data_source *source = wl_resource_get_user_data(resource);
    if (source->server && source->server->selection_source == resource)
        source->server->selection_source = NULL;
    free(source);
}

static void device_start_drag(struct wl_client *client, struct wl_resource *resource,
                              struct wl_resource *source, struct wl_resource *origin,
                              struct wl_resource *icon, uint32_t serial) {
    dnd_start_drag(wl_resource_get_user_data(resource), client, source, origin, icon, serial);
}

static void device_set_selection(struct wl_client *client, struct wl_resource *resource,
                                 struct wl_resource *source_resource, uint32_t serial) {
    struct server *s = wl_resource_get_user_data(resource);
    if (!source_resource) return;
    struct data_source *source = wl_resource_get_user_data(source_resource);
    if (source->mime < 0) {
        wl_data_source_send_cancelled(source_resource);
        return;
    }
    replace_selection_source(s, source_resource);
    int fds[2];
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) < 0) return;
    struct pipe_reader *r = calloc(1, sizeof(*r));
    if (!r) {
        close(fds[0]);
        close(fds[1]);
        return;
    }
    r->server = s;
    r->fd = fds[0];
    r->source = wl_event_loop_add_fd(s->loop, fds[0], WL_EVENT_READABLE, reader_readable, r);
    wl_data_source_send_send(source_resource, text_mimes[source->mime], fds[1]);
    close(fds[1]);
}

static const struct wl_data_device_interface device_impl = {
    .start_drag = device_start_drag,
    .set_selection = device_set_selection,
    .release = destroy_request,
};

static void ddm_create_data_source(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct data_source *source = calloc(1, sizeof(*source));
    struct wl_resource *r = source ? wl_resource_create(client, &wl_data_source_interface,
                                                        wl_resource_get_version(resource), id) : NULL;
    if (!r) {
        free(source);
        wl_client_post_no_memory(client);
        return;
    }
    source->resource = r;
    source->server = wl_resource_get_user_data(resource);
    source->mime = -1;
    wl_resource_set_implementation(r, &source_impl, source, source_resource_destroy);
}

static void ddm_get_data_device(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                struct wl_resource *seat) {
    struct server *s = wl_resource_get_user_data(resource);
    struct wl_resource *device = wl_resource_create(client, &wl_data_device_interface,
                                                    wl_resource_get_version(resource), id);
    if (!device) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(device, &device_impl, s, resource_unlink);
    wl_list_insert(&s->data_devices, wl_resource_get_link(device));
    if (s->keyboard_focus && wl_resource_get_client(s->keyboard_focus->resource) == client)
        offer_to_device(s, device);
}

static const struct wl_data_device_manager_interface ddm_impl = {
    .create_data_source = ddm_create_data_source,
    .get_data_device = ddm_get_data_device,
};

static void ddm_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &wl_data_device_manager_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &ddm_impl, data, NULL);
}

void clipboard_init(struct server *s) {
    wl_list_init(&s->data_devices);
    /* Created here so it exists in the fakefs; the host only overwrites its contents. */
    char path[256];
    snprintf(path, sizeof(path), "%s/clipboard-in", s->runtime_dir);
    int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
    if (fd >= 0) close(fd);
    wl_global_create(s->display, &wl_data_device_manager_interface, 3, s, ddm_bind);
}
