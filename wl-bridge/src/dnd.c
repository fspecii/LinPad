/* Drag and drop: wl_data_device.start_drag between Linux clients, Linux drags that end
 * on native host UI, and host drags (native windows, other iPadOS apps) into Linux
 * clients. The protocol with the host is in DND-SPEC.md.
 *
 * The clipboard (clipboard.c) owns the wl_data_device_manager global and the
 * wl_data_source objects; it tells this file about every source's MIME types and
 * actions, and hands start_drag over. */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ishwl.h"

#define MAX_MIMES 32
#define MAX_PARKED 8
#define MAX_HANDOVER (64 << 20)
#define ACTION_COPY WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY
#define ACTION_MOVE WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE
#define ACTION_ASK WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK

struct mime_list {
    int count;
    char *types[MAX_MIMES];
    char *paths[MAX_MIMES]; /* host drags: where the data for each type is */
};

static void mimes_clear(struct mime_list *l) {
    for (int i = 0; i < l->count; i++) {
        free(l->types[i]);
        free(l->paths[i]);
    }
    memset(l, 0, sizeof(*l));
}

static int mimes_find(const struct mime_list *l, const char *mime) {
    for (int i = 0; i < l->count; i++)
        if (strcmp(l->types[i], mime) == 0) return i;
    return -1;
}

static void mimes_add(struct mime_list *l, const char *mime, const char *path) {
    int i = mimes_find(l, mime);
    if (i < 0) {
        if (l->count >= MAX_MIMES) return;
        i = l->count++;
        l->types[i] = strdup(mime);
        l->paths[i] = NULL;
    }
    if (path) {
        free(l->paths[i]);
        l->paths[i] = strdup(path);
    }
}

/* ---- what each wl_data_source offers ---- */

struct source_info {
    struct wl_resource *resource;
    struct wl_listener destroy;
    struct wl_list link;
    struct mime_list mimes;
    uint32_t actions;
    bool has_actions;
};

static struct wl_list sources;

/* A drop target: the surface the pointer is over and the offer it was given. */
struct target {
    struct surface *surface;
    struct wl_listener surface_destroy;
    struct wl_resource *device;
    struct wl_resource *offer;
};

static struct {
    struct server *s;
    int fd; /* the dnd FIFO, ishwl → host */

    /* A drag started by a Linux client. */
    bool active;
    struct wl_resource *source; /* NULL: a client-internal drag */
    struct wl_client *origin;
    struct target t;
    char *accepted;
    uint32_t target_actions, target_preferred, action;
    bool over_host, host_accepts;
    struct wl_resource *dropped_offer; /* waiting for its finish */
    bool dropped_finished;

    /* A drag from the host into a Linux client. */
    struct {
        bool active;
        struct target t;
        struct mime_list mimes; /* offered types; paths once the manifest is in */
        bool data_ready;
        uint32_t actions, preferred;
        char *accepted;
        uint32_t target_actions, target_preferred, action;
        int reported_accepted, reported_action;
        struct wl_resource *dropped_offer;
        struct { char *mime; int fd; } parked[MAX_PARKED];
        int parked_count;
    } host;
} dnd = {.fd = -1};

static void dnd_send(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void dnd_send(const char *fmt, ...) {
    if (dnd.fd < 0) return;
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof(line) - 1, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n > (int) sizeof(line) - 2) n = sizeof(line) - 2;
    line[n++] = '\n';
    if (write(dnd.fd, line, n) != n)
        log_msg(dnd.s, "dnd write failed (%s), host not reading?", strerror(errno));
}

static struct source_info *source_info(struct wl_resource *resource) {
    struct source_info *info;
    wl_list_for_each(info, &sources, link)
        if (info->resource == resource) return info;
    return NULL;
}

static void client_drag_cancel(const char *why);

static void source_info_destroyed(struct wl_listener *listener, void *data) {
    struct source_info *info = wl_container_of(listener, info, destroy);
    if (dnd.source == info->resource) {
        dnd.source = NULL;
        if (dnd.active) client_drag_cancel("source destroyed");
        dnd.dropped_offer = NULL;
    }
    wl_list_remove(&info->link);
    mimes_clear(&info->mimes);
    free(info);
}

static struct source_info *source_info_get(struct wl_resource *resource) {
    struct source_info *info = source_info(resource);
    if (info) return info;
    info = calloc(1, sizeof(*info));
    if (!info) return NULL;
    info->resource = resource;
    info->destroy.notify = source_info_destroyed;
    wl_resource_add_destroy_listener(resource, &info->destroy);
    wl_list_insert(&sources, &info->link);
    return info;
}

void dnd_source_offer(struct wl_resource *source, const char *mime) {
    struct source_info *info = source_info_get(source);
    if (info) mimes_add(&info->mimes, mime, NULL);
}

void dnd_source_actions(struct wl_resource *source, uint32_t actions) {
    struct source_info *info = source_info_get(source);
    if (!info) return;
    info->actions = actions;
    info->has_actions = true;
}

/* Sources from v1/v2 clients never set actions; they mean copy. */
static uint32_t source_actions(void) {
    struct source_info *info = dnd.source ? source_info(dnd.source) : NULL;
    return info && info->has_actions ? info->actions : ACTION_COPY;
}

/* ---- targets ---- */

static bool device_alive(struct wl_resource *device) {
    struct wl_resource *d;
    wl_resource_for_each(d, &dnd.s->data_devices)
        if (d == device) return true;
    return false;
}

static struct wl_resource *device_for(struct wl_client *client) {
    struct wl_resource *d;
    wl_resource_for_each(d, &dnd.s->data_devices)
        if (wl_resource_get_client(d) == client) return d;
    return NULL;
}

static void target_surface_destroyed(struct wl_listener *listener, void *data) {
    struct target *t = wl_container_of(listener, t, surface_destroy);
    wl_list_remove(&t->surface_destroy.link);
    wl_list_init(&t->surface_destroy.link);
    t->surface = NULL;
    t->device = NULL;
    t->offer = NULL;
}

/* Forgets the target without telling it: after a drop the offer stays the client's. */
static void target_detach(struct target *t) {
    if (t->surface) {
        wl_list_remove(&t->surface_destroy.link);
        wl_list_init(&t->surface_destroy.link);
    }
    t->surface = NULL;
    t->device = NULL;
    t->offer = NULL;
}

static void target_leave(struct target *t) {
    if (t->surface && t->device && device_alive(t->device))
        wl_data_device_send_leave(t->device);
    target_detach(t);
}

static const struct wl_data_offer_interface offer_impl;
static void offer_destroyed(struct wl_resource *resource);

static void target_enter(struct target *t, struct surface *surface, double sx, double sy,
                         const struct mime_list *mimes, uint32_t actions, bool with_offer) {
    struct wl_client *client = wl_resource_get_client(surface->resource);
    struct wl_resource *device = device_for(client);
    if (!device) return;
    struct wl_resource *offer = NULL;
    if (with_offer) {
        offer = wl_resource_create(client, &wl_data_offer_interface, wl_resource_get_version(device), 0);
        if (!offer) return;
        wl_resource_set_implementation(offer, &offer_impl, NULL, offer_destroyed);
        wl_data_device_send_data_offer(device, offer);
        for (int i = 0; i < mimes->count; i++)
            wl_data_offer_send_offer(offer, mimes->types[i]);
        if (wl_resource_get_version(offer) >= WL_DATA_OFFER_SOURCE_ACTIONS_SINCE_VERSION)
            wl_data_offer_send_source_actions(offer, actions);
    }
    wl_data_device_send_enter(device, wl_display_next_serial(dnd.s->display), surface->resource,
                              wl_fixed_from_double(sx), wl_fixed_from_double(sy), offer);
    t->surface = surface;
    t->device = device;
    t->offer = offer;
    wl_signal_add(&surface->destroy_signal, &t->surface_destroy);
}

static void target_motion(struct target *t, double sx, double sy) {
    if (t->surface && t->device && device_alive(t->device))
        wl_data_device_send_motion(t->device, now_ms(), wl_fixed_from_double(sx), wl_fixed_from_double(sy));
}

/* The surface under a view-local point, as the pointer would find it. */
static struct surface *surface_under(uint32_t view_id, double x, double y, double *sx, double *sy) {
    struct view *v = view_by_id(dnd.s, view_id);
    if (!v || !v->mapped || !v->xdg || !v->xdg->surface) return NULL;
    struct box g = v->xdg->geometry;
    return surface_at(v->xdg->surface, x + g.x, y + g.y, sx, sy);
}

/* weston's choice: the target's preferred action if both sides allow it, else the
 * first common one in copy, move, ask order. */
static uint32_t choose_action(uint32_t offered, uint32_t wanted, uint32_t preferred) {
    uint32_t common = offered & wanted;
    if (preferred & common) return preferred;
    if (common & ACTION_COPY) return ACTION_COPY;
    if (common & ACTION_MOVE) return ACTION_MOVE;
    if (common & ACTION_ASK) return ACTION_ASK;
    return 0;
}

static bool offer_v3(struct wl_resource *offer) {
    return offer && wl_resource_get_version(offer) >= WL_DATA_OFFER_ACTION_SINCE_VERSION;
}

static bool source_v3(void) {
    return dnd.source && wl_resource_get_version(dnd.source) >= WL_DATA_SOURCE_ACTION_SINCE_VERSION;
}

/* ---- host drags: answering receive from the manifest's files ---- */

struct file_writer {
    struct wl_event_source *source;
    int in, out;
    char buf[65536];
    size_t len, off;
};

static void file_writer_finish(struct file_writer *w) {
    if (w->source) wl_event_source_remove(w->source);
    close(w->in);
    close(w->out);
    free(w);
}

static int file_writer_writable(int fd, uint32_t mask, void *data) {
    struct file_writer *w = data;
    for (;;) {
        if (w->off == w->len) {
            ssize_t n = read(w->in, w->buf, sizeof(w->buf));
            if (n <= 0) break;
            w->len = n;
            w->off = 0;
        }
        ssize_t n = write(w->out, w->buf + w->off, w->len - w->off);
        if (n < 0 && errno == EAGAIN) return 0;
        if (n <= 0) break;
        w->off += n;
    }
    file_writer_finish(w);
    return 0;
}

static void host_write_data(const char *mime, int fd) {
    int i = mimes_find(&dnd.host.mimes, mime);
    int in = i >= 0 && dnd.host.mimes.paths[i] ? open(dnd.host.mimes.paths[i], O_RDONLY | O_CLOEXEC) : -1;
    struct file_writer *w = in >= 0 ? calloc(1, sizeof(*w)) : NULL;
    if (!w) {
        if (in >= 0) close(in);
        close(fd);
        return;
    }
    w->in = in;
    w->out = fd;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    w->source = wl_event_loop_add_fd(dnd.s->loop, fd, WL_EVENT_WRITABLE, file_writer_writable, w);
    if (!w->source) file_writer_finish(w);
}

static void host_unpark(bool deliver) {
    for (int i = 0; i < dnd.host.parked_count; i++) {
        if (deliver)
            host_write_data(dnd.host.parked[i].mime, dnd.host.parked[i].fd);
        else
            close(dnd.host.parked[i].fd);
        free(dnd.host.parked[i].mime);
    }
    dnd.host.parked_count = 0;
}

static void host_report_status(void) {
    int accepted = dnd.host.accepted != NULL;
    if (accepted == dnd.host.reported_accepted && (int) dnd.host.action == dnd.host.reported_action)
        return;
    dnd.host.reported_accepted = accepted;
    dnd.host.reported_action = (int) dnd.host.action;
    dnd_send("dnd_status %d %u", accepted, dnd.host.action);
}

static void host_reset(void) {
    target_leave(&dnd.host.t);
    host_unpark(false);
    mimes_clear(&dnd.host.mimes);
    free(dnd.host.accepted);
    dnd.host.accepted = NULL;
    dnd.host.active = false;
    dnd.host.data_ready = false;
    dnd.host.target_actions = dnd.host.target_preferred = dnd.host.action = 0;
    dnd.host.reported_accepted = dnd.host.reported_action = -1;
    dnd.host.dropped_offer = NULL;
}

/* ---- offers ---- */

static bool is_client_offer(struct wl_resource *offer) {
    return offer && (offer == dnd.t.offer || offer == dnd.dropped_offer);
}

static bool is_host_offer(struct wl_resource *offer) {
    return offer && (offer == dnd.host.t.offer || offer == dnd.host.dropped_offer);
}

static void client_negotiate(void) {
    struct wl_resource *offer = dnd.t.offer ? dnd.t.offer : dnd.dropped_offer;
    uint32_t action = choose_action(source_actions(), dnd.target_actions, dnd.target_preferred);
    if (action == dnd.action) return;
    dnd.action = action;
    if (offer_v3(offer)) wl_data_offer_send_action(offer, action);
    if (source_v3()) wl_data_source_send_action(dnd.source, action);
}

static void host_negotiate(void) {
    struct wl_resource *offer = dnd.host.t.offer ? dnd.host.t.offer : dnd.host.dropped_offer;
    uint32_t action = choose_action(dnd.host.actions, dnd.host.target_actions, dnd.host.target_preferred);
    if (action != dnd.host.action) {
        dnd.host.action = action;
        if (offer_v3(offer)) wl_data_offer_send_action(offer, action);
    }
    host_report_status();
}

static void offer_accept(struct wl_client *client, struct wl_resource *resource, uint32_t serial, const char *mime) {
    if (is_client_offer(resource)) {
        free(dnd.accepted);
        dnd.accepted = mime ? strdup(mime) : NULL;
        if (dnd.source) wl_data_source_send_target(dnd.source, mime);
    } else if (is_host_offer(resource)) {
        free(dnd.host.accepted);
        dnd.host.accepted = mime ? strdup(mime) : NULL;
        host_report_status();
    }
}

static void offer_receive(struct wl_client *client, struct wl_resource *resource, const char *mime, int32_t fd) {
    if (is_client_offer(resource) && dnd.source) {
        wl_data_source_send_send(dnd.source, mime, fd);
        close(fd);
    } else if (is_host_offer(resource)) {
        if (dnd.host.data_ready) {
            host_write_data(mime, fd);
        } else if (dnd.host.parked_count < MAX_PARKED) {
            dnd.host.parked[dnd.host.parked_count].mime = strdup(mime);
            dnd.host.parked[dnd.host.parked_count++].fd = fd;
        } else {
            close(fd);
        }
    } else {
        close(fd);
    }
}

static void client_drop_finished(bool finished) {
    if (dnd.source && source_v3()) {
        if (finished) wl_data_source_send_dnd_finished(dnd.source);
        else wl_data_source_send_cancelled(dnd.source);
    }
    dnd.dropped_offer = NULL;
    if (!dnd.active) dnd.source = NULL;
}

static void offer_finish(struct wl_client *client, struct wl_resource *resource) {
    if (resource == dnd.dropped_offer) {
        dnd.dropped_finished = true;
        client_drop_finished(true);
    } else if (resource == dnd.host.dropped_offer) {
        dnd_send("dnd_done");
        host_reset();
    }
}

static void offer_set_actions(struct wl_client *client, struct wl_resource *resource,
                              uint32_t actions, uint32_t preferred) {
    if (is_client_offer(resource)) {
        dnd.target_actions = actions;
        dnd.target_preferred = preferred;
        client_negotiate();
    } else if (is_host_offer(resource)) {
        dnd.host.target_actions = actions;
        dnd.host.target_preferred = preferred;
        host_negotiate();
    }
}

static void offer_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static const struct wl_data_offer_interface offer_impl = {
    .accept = offer_accept,
    .receive = offer_receive,
    .destroy = offer_destroy,
    .finish = offer_finish,
    .set_actions = offer_set_actions,
};

/* A v1/v2 target never calls finish: destroying the dropped offer is its finish, as in
 * weston. A v3 target that destroys it unfinished cancelled the drop. */
static void offer_destroyed(struct wl_resource *resource) {
    if (resource == dnd.dropped_offer) {
        client_drop_finished(!offer_v3(resource) || dnd.dropped_finished);
    } else if (resource == dnd.host.dropped_offer) {
        dnd_send("dnd_done");
        dnd.host.dropped_offer = NULL;
        host_reset();
    }
    if (resource == dnd.t.offer) dnd.t.offer = NULL;
    if (resource == dnd.host.t.offer) dnd.host.t.offer = NULL;
}

/* ---- drags started by a client ---- */

static void end_grab(void) {
    dnd.active = false;
    dnd.over_host = dnd.host_accepts = false;
    free(dnd.accepted);
    dnd.accepted = NULL;
    dnd.target_actions = dnd.target_preferred = dnd.action = 0;
    dnd.s->buttons_down = 0;
}

static void client_drag_cancel(const char *why) {
    target_leave(&dnd.t);
    if (dnd.source) wl_data_source_send_cancelled(dnd.source);
    log_msg(dnd.s, "dnd: cancelled (%s)", why);
    dnd_send("dnd_end cancelled");
    end_grab();
    dnd.source = NULL;
}

/* The pointer focus loses the pointer for the length of the drag, as in weston, so the
 * source's toolkit drops its implicit grab and the release never reaches it. */
static void pointer_leave_for_drag(struct server *s) {
    struct surface *focus = s->pointer_focus;
    if (!focus) return;
    uint32_t serial = wl_display_next_serial(s->display);
    struct wl_resource *p;
    wl_resource_for_each(p, &s->pointer_resources) {
        if (wl_resource_get_client(p) != wl_resource_get_client(focus->resource)) continue;
        wl_pointer_send_leave(p, serial, focus->resource);
        if (wl_resource_get_version(p) >= WL_POINTER_FRAME_SINCE_VERSION)
            wl_pointer_send_frame(p);
    }
    wl_list_remove(&s->pointer_focus_destroy.link);
    wl_list_init(&s->pointer_focus_destroy.link);
    s->pointer_focus = NULL;
}

void dnd_start_drag(struct server *s, struct wl_client *client, struct wl_resource *source,
                    struct wl_resource *origin, struct wl_resource *icon, uint32_t serial) {
    if (dnd.active || !s->buttons_down) {
        if (source) wl_data_source_send_cancelled(source);
        return;
    }
    if (dnd.dropped_offer) client_drop_finished(false);
    dnd.active = true;
    dnd.source = source;
    dnd.origin = client;
    dnd.dropped_finished = false;
    pointer_leave_for_drag(s);
    struct source_info *info = source ? source_info_get(source) : NULL;
    char list[400] = "";
    size_t used = 0;
    for (int i = 0; info && i < info->mimes.count; i++) {
        int n = snprintf(list + used, sizeof(list) - used, "%s%s", used ? "," : "", info->mimes.types[i]);
        if (n < 0 || used + n >= sizeof(list)) break;
        used += n;
    }
    char *escaped = bridge_escape(list);
    dnd_send("dnd_start %s %u", escaped ? escaped : "-", source_actions());
    free(escaped);
    log_msg(s, "dnd: start (%s)", list[0] ? list : "internal");
}

bool dnd_grabs_pointer(struct server *s) {
    return dnd.active;
}

static void client_drag_over(uint32_t view_id, double x, double y) {
    double sx = 0, sy = 0;
    struct surface *surface = surface_under(view_id, x, y, &sx, &sy);
    /* A drag without a source stays inside its own client. */
    if (surface && !dnd.source && wl_resource_get_client(surface->resource) != dnd.origin)
        surface = NULL;
    dnd.over_host = false;
    if (surface == dnd.t.surface) {
        target_motion(&dnd.t, sx, sy);
        return;
    }
    target_leave(&dnd.t);
    free(dnd.accepted);
    dnd.accepted = NULL;
    dnd.target_actions = dnd.target_preferred = dnd.action = 0;
    if (dnd.source) wl_data_source_send_target(dnd.source, NULL);
    if (!surface) return;
    struct source_info *info = dnd.source ? source_info(dnd.source) : NULL;
    static const struct mime_list none;
    target_enter(&dnd.t, surface, sx, sy, info ? &info->mimes : &none, source_actions(), dnd.source != NULL);
}

/* Native host UI takes the drop: read the best type out of the source. */
static const char *const handover_types[] = {
    "text/uri-list", "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "image/png",
};

struct handover {
    struct wl_event_source *source;
    struct wl_resource *data_source;
    struct wl_listener data_source_destroy;
    int fd;
    char *mime;
    char *data;
    size_t len, cap;
};

static void handover_free(struct handover *h) {
    if (h->source) wl_event_source_remove(h->source);
    if (h->data_source) wl_list_remove(&h->data_source_destroy.link);
    close(h->fd);
    free(h->mime);
    free(h->data);
    free(h);
}

static void handover_source_destroyed(struct wl_listener *listener, void *data) {
    struct handover *h = wl_container_of(listener, h, data_source_destroy);
    wl_list_remove(&h->data_source_destroy.link);
    h->data_source = NULL;
}

static void handover_done(struct handover *h) {
    char path[300], tmp[310];
    snprintf(path, sizeof(path), "%s/dnd-out", dnd.s->runtime_dir);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    bool ok = f && fwrite(h->data ? h->data : "", 1, h->len, f) == h->len;
    if (f && fclose(f) != 0) ok = false;
    if (ok && rename(tmp, path) == 0) {
        char *mime = bridge_escape(h->mime);
        dnd_send("dnd_data %s dnd-out", mime ? mime : "-");
        free(mime);
    }
    /* Copy, whatever the user asked for: the host moves the files itself, so the source
     * must never delete the originals. */
    if (h->data_source && wl_resource_get_version(h->data_source) >= WL_DATA_SOURCE_ACTION_SINCE_VERSION) {
        wl_data_source_send_action(h->data_source, ACTION_COPY);
        wl_data_source_send_dnd_drop_performed(h->data_source);
        wl_data_source_send_dnd_finished(h->data_source);
    }
    dnd_send("dnd_end host");
    handover_free(h);
}

static int handover_readable(int fd, uint32_t mask, void *data) {
    struct handover *h = data;
    for (;;) {
        if (h->len == h->cap) {
            size_t cap = h->cap ? h->cap * 2 : 4096;
            char *grown = cap <= MAX_HANDOVER ? realloc(h->data, cap) : NULL;
            if (!grown) break;
            h->data = grown;
            h->cap = cap;
        }
        ssize_t n = read(fd, h->data + h->len, h->cap - h->len);
        if (n < 0 && errno == EAGAIN) return 0;
        if (n <= 0) break;
        h->len += n;
    }
    handover_done(h);
    return 0;
}

static bool hand_over_to_host(void) {
    struct source_info *info = dnd.source ? source_info(dnd.source) : NULL;
    if (!info) return false;
    const char *mime = NULL;
    for (size_t i = 0; !mime && i < sizeof(handover_types) / sizeof(*handover_types); i++)
        if (mimes_find(&info->mimes, handover_types[i]) >= 0) mime = handover_types[i];
    int fds[2];
    if (!mime || pipe2(fds, O_CLOEXEC | O_NONBLOCK) < 0) return false;
    struct handover *h = calloc(1, sizeof(*h));
    if (!h) {
        close(fds[0]);
        close(fds[1]);
        return false;
    }
    h->fd = fds[0];
    h->mime = strdup(mime);
    h->data_source = dnd.source;
    h->data_source_destroy.notify = handover_source_destroyed;
    wl_resource_add_destroy_listener(dnd.source, &h->data_source_destroy);
    h->source = wl_event_loop_add_fd(dnd.s->loop, fds[0], WL_EVENT_READABLE, handover_readable, h);
    wl_data_source_send_send(dnd.source, mime, fds[1]);
    close(fds[1]);
    return true;
}

static void client_drag_drop(void) {
    struct target *t = &dnd.t;
    bool can_drop = t->surface && t->device && device_alive(t->device) &&
                    (!dnd.source || (dnd.accepted && (!offer_v3(t->offer) || dnd.action)));
    if (can_drop) {
        wl_data_device_send_drop(t->device);
        if (source_v3()) wl_data_source_send_dnd_drop_performed(dnd.source);
        dnd.dropped_offer = t->offer;
        target_detach(t);
        dnd_send("dnd_end dropped");
        log_msg(dnd.s, "dnd: dropped on a client");
        struct wl_resource *source = dnd.source;
        end_grab();
        dnd.source = source;
        if (!dnd.dropped_offer) dnd.source = NULL;
        return;
    }
    if (dnd.over_host && dnd.host_accepts && hand_over_to_host()) {
        log_msg(dnd.s, "dnd: handing over to the host");
        end_grab();
        dnd.source = NULL;
        return;
    }
    client_drag_cancel("released over nothing");
}

/* Called first in seat_pointer_button: while a drag runs the seat sees no buttons. */
bool dnd_pointer_button(struct server *s, uint32_t button, bool pressed) {
    if (!dnd.active) return false;
    if (!pressed) client_drag_drop();
    return true;
}

/* ---- drags from the host ---- */

static void host_over(uint32_t view_id, double x, double y) {
    double sx = 0, sy = 0;
    struct surface *surface = surface_under(view_id, x, y, &sx, &sy);
    if (surface == dnd.host.t.surface) {
        target_motion(&dnd.host.t, sx, sy);
        return;
    }
    target_leave(&dnd.host.t);
    free(dnd.host.accepted);
    dnd.host.accepted = NULL;
    dnd.host.target_actions = dnd.host.target_preferred = dnd.host.action = 0;
    if (surface)
        target_enter(&dnd.host.t, surface, sx, sy, &dnd.host.mimes, dnd.host.actions, true);
    host_report_status();
}

static void host_load_manifest(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        log_msg(dnd.s, "dnd: cannot read manifest %s", path);
        return;
    }
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = '\0';
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = '\0';
        mimes_add(&dnd.host.mimes, line, tab + 1);
    }
    fclose(f);
    dnd.host.data_ready = true;
    host_unpark(true);
}

static void host_drop(uint32_t view_id, double x, double y) {
    host_over(view_id, x, y);
    struct target *t = &dnd.host.t;
    if (!t->surface || !t->offer || !t->device || !device_alive(t->device)) {
        dnd_send("dnd_status 0 0");
        host_reset();
        return;
    }
    /* Toolkits often answer accept only after reading the data, which may not have
     * happened yet; the drop goes through and the client decides then. */
    if (offer_v3(t->offer) && dnd.host.action == 0) {
        dnd.host.action = dnd.host.preferred ? dnd.host.preferred : ACTION_COPY;
        wl_data_offer_send_action(t->offer, dnd.host.action);
    }
    wl_data_device_send_drop(t->device);
    dnd.host.dropped_offer = t->offer;
    target_detach(t);
    log_msg(dnd.s, "dnd: host drop delivered");
}

/* ---- host messages ---- */

static void unescape_field(char *s) {
    if (strcmp(s, "-") == 0) {
        *s = '\0';
        return;
    }
    char *o = s;
    for (char *p = s; *p; p++) {
        if (p[0] == '%' && p[1] && p[2]) {
            char hex[3] = {p[1], p[2], 0};
            *o++ = (char) strtol(hex, NULL, 16);
            p += 2;
        } else {
            *o++ = *p;
        }
    }
    *o = '\0';
}

void dnd_handle(struct server *s, int argc, char **argv) {
    const char *cmd = argv[0];
#define ARGU(i) (argc > (i) ? (uint32_t) strtoul(argv[i], NULL, 10) : 0)
#define ARGF(i) (argc > (i) ? strtod(argv[i], NULL) : 0.0)
    if (strcmp(cmd, "dnd_over") == 0) {
        if (!dnd.active) return;
        uint32_t view = ARGU(1);
        if (view) {
            client_drag_over(view, ARGF(2), ARGF(3));
        } else {
            target_leave(&dnd.t);
            if (dnd.source && dnd.accepted) wl_data_source_send_target(dnd.source, NULL);
            free(dnd.accepted);
            dnd.accepted = NULL;
            dnd.over_host = true;
            dnd.host_accepts = ARGU(2) != 0;
        }
    } else if (strcmp(cmd, "dnd_cancel") == 0) {
        if (dnd.active) client_drag_cancel("host cancelled");
    } else if (strcmp(cmd, "dnd_enter") == 0 && argc > 6) {
        host_reset();
        dnd.host.active = true;
        dnd.host.actions = ARGU(4) ? ARGU(4) : ACTION_COPY;
        dnd.host.preferred = ARGU(5);
        unescape_field(argv[6]);
        for (char *mime = strtok(argv[6], ","); mime; mime = strtok(NULL, ","))
            mimes_add(&dnd.host.mimes, mime, NULL);
        host_over(ARGU(1), ARGF(2), ARGF(3));
    } else if (strcmp(cmd, "dnd_motion") == 0) {
        if (dnd.host.active) host_over(ARGU(1), ARGF(2), ARGF(3));
    } else if (strcmp(cmd, "dnd_data_ready") == 0 && argc > 1) {
        if (!dnd.host.active) return;
        unescape_field(argv[1]);
        host_load_manifest(argv[1]);
    } else if (strcmp(cmd, "dnd_leave") == 0) {
        if (dnd.host.active && !dnd.host.dropped_offer) host_reset();
    } else if (strcmp(cmd, "dnd_drop") == 0) {
        if (dnd.host.active) host_drop(ARGU(1), ARGF(2), ARGF(3));
    } else {
        log_msg(s, "unknown dnd message '%s'", cmd);
    }
#undef ARGU
#undef ARGF
}

void dnd_init(struct server *s) {
    dnd.s = s;
    wl_list_init(&sources);
    wl_list_init(&dnd.t.surface_destroy.link);
    wl_list_init(&dnd.host.t.surface_destroy.link);
    dnd.t.surface_destroy.notify = target_surface_destroyed;
    dnd.host.t.surface_destroy.notify = target_surface_destroyed;
    dnd.host.reported_accepted = dnd.host.reported_action = -1;
    char path[256];
    snprintf(path, sizeof(path), "%s/dnd", s->runtime_dir);
    struct stat st;
    if (stat(path, &st) == 0 && !S_ISFIFO(st.st_mode))
        unlink(path);
    if (mkfifo(path, 0600) < 0 && errno != EEXIST) {
        log_msg(s, "dnd: mkfifo %s: %s", path, strerror(errno));
        return;
    }
    /* O_RDWR so writes never fail with ENXIO before the host opens its end. */
    dnd.fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
}
