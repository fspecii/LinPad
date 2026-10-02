/* Exporting views: each mapped toplevel or popup is composited (with its
 * subsurfaces) into its own file under runtime_dir, mapped MAP_SHARED. In iSH a
 * shared mapping of a fakefs file is a host mmap of the backing file, so the
 * iOS side maps the same file and reads the pixels with no further copies. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "ishwl.h"

static void out_release(struct out_buffer *out) {
    if (out->data && out->data != MAP_FAILED)
        munmap(out->data, (size_t) out->stride * out->height);
    if (out->fd >= 0)
        close(out->fd);
    if (out->path[0])
        unlink(out->path);
    out->data = NULL;
    out->fd = -1;
    out->path[0] = '\0';
    out->width = out->height = 0;
}

/* A resize gets a new file instead of an ftruncate, so a host mapping of the old
 * file never sees it shrink underneath (which would SIGBUS the app). */
static bool out_ensure(struct view *v, int32_t w, int32_t h) {
    struct out_buffer *out = &v->out;
    if (out->data && out->width == w && out->height == h)
        return true;
    uint32_t generation = out->generation + 1;
    out_release(out);
    out->generation = generation;
    out->width = w;
    out->height = h;
    out->stride = w * 4;
    snprintf(out->path, sizeof(out->path), "%s/v%u-%u.buf", v->server->runtime_dir, v->id, generation);
    size_t size = (size_t) out->stride * h;
    out->fd = open(out->path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out->fd < 0 || ftruncate(out->fd, size) < 0)
        goto fail;
    out->data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, out->fd, 0);
    if (out->data == MAP_FAILED)
        goto fail;
    return true;
fail:
    log_msg(v->server, "cannot create %s", out->path);
    out_release(out);
    return false;
}

void view_damage(struct view *v, struct box b) {
    v->damage = box_union(v->damage, b);
    view_schedule(v);
}

void view_schedule(struct view *v) {
    struct server *s = v->server;
    v->needs_composite = true;
    if (!s->composite_idle)
        s->composite_idle = wl_event_loop_add_idle(s->loop, composite_all, s);
}

struct blit_ctx {
    struct view *view;
    struct box clip;
    int32_t scale;
    bool first;
    int32_t origin_x, origin_y;
};

static void collect_callbacks(struct surface *s, int32_t x, int32_t y, void *data) {
    struct view *v = data;
    wl_list_insert_list(v->presented_callbacks.prev, &s->frame_callbacks);
    wl_list_init(&s->frame_callbacks);
}

static inline uint32_t blend(uint32_t dst, uint32_t src) {
    uint32_t alpha = src >> 24;
    if (alpha == 0xff) return src;
    if (alpha == 0) return dst;
    uint32_t inv = 255 - alpha;
    uint32_t rb = ((dst & 0x00ff00ffu) * inv + 0x00800080u) >> 8 & 0x00ff00ffu;
    uint32_t ag = ((dst >> 8 & 0x00ff00ffu) * inv + 0x00800080u) & 0xff00ff00u;
    return src + rb + ag;
}

/* `x`, `y` are the surface's position in view coordinates (logical); the clip
 * and the output are in pixels at ctx->scale. */
static void blit_surface(struct surface *s, int32_t x, int32_t y, void *data) {
    struct blit_ctx *ctx = data;
    struct shm_buffer *b = s->buffer ? shm_buffer_from_resource(s->buffer) : NULL;
    bool copy = ctx->first;
    ctx->first = false;
    if (!b) return;
    const int32_t scale = ctx->scale;
    const int32_t px = x * scale, py = y * scale;
    struct box r = box_intersect(ctx->clip, (struct box) {px, py, s->width * scale, s->height * scale});
    if (box_empty(r)) return;

    struct out_buffer *out = &ctx->view->out;
    const uint8_t *src_base = shm_buffer_data(b);
    const bool alpha = shm_buffer_has_alpha(b);
    const bool direct = s->scale == scale && s->viewport.src_w < 0 && s->viewport.dst_w < 0;
    /* Source rectangle in buffer pixels (wp_viewport crop, or the whole buffer). */
    const double sx0 = s->viewport.src_w > 0 ? s->viewport.src_x * s->scale : 0;
    const double sy0 = s->viewport.src_w > 0 ? s->viewport.src_y * s->scale : 0;
    const double sw = s->viewport.src_w > 0 ? s->viewport.src_w * s->scale : b->width;
    const double sh = s->viewport.src_w > 0 ? s->viewport.src_h * s->scale : b->height;
    const double xstep = sw / (s->width * scale), ystep = sh / (s->height * scale);
    for (int32_t row = r.y; row < r.y + r.h; row++) {
        uint32_t *dst = (uint32_t *) ((uint8_t *) out->data + (size_t) row * out->stride) + r.x;
        if (direct) {
            const uint32_t *src = (const uint32_t *) (src_base + (size_t) (row - py) * b->stride) + (r.x - px);
            if (copy) {
                memcpy(dst, src, (size_t) r.w * 4);
            } else if (!alpha) {
                for (int32_t i = 0; i < r.w; i++)
                    dst[i] = src[i] | 0xff000000u;
            } else {
                for (int32_t i = 0; i < r.w; i++)
                    dst[i] = blend(dst[i], src[i]);
            }
            continue;
        }
        /* Scaled (other buffer scale, or wp_viewport): nearest-neighbour. */
        int32_t sy = (int32_t) (sy0 + (row - py) * ystep);
        if (sy < 0 || sy >= b->height) continue;
        const uint32_t *src_row = (const uint32_t *) (src_base + (size_t) sy * b->stride);
        for (int32_t i = 0; i < r.w; i++) {
            int32_t sx = (int32_t) (sx0 + (r.x + i - px) * xstep);
            if (sx < 0 || sx >= b->width) continue;
            uint32_t sp = alpha ? src_row[sx] : src_row[sx] | 0xff000000u;
            dst[i] = copy ? sp : blend(dst[i], sp);
        }
    }
}

static bool view_has_below_children(struct surface *root) {
    struct subsurface *sub;
    wl_list_for_each(sub, &root->children, link)
        if (sub->below_parent) return true;
    return false;
}

static void view_write_png(struct view *v) {
    struct server *s = v->server;
    char path[512];
    const char *name = v->app_id && *v->app_id ? v->app_id : (v->kind == VIEW_POPUP ? "popup" : "view");
    snprintf(path, sizeof(path), "%s/%s-%u.png", s->png_dir, name, v->id);
    bool alpha = v->xdg && v->xdg->surface && v->xdg->surface->buffer &&
                 shm_buffer_from_resource(v->xdg->surface->buffer) &&
                 shm_buffer_has_alpha(shm_buffer_from_resource(v->xdg->surface->buffer));
    if (png_write(path, v->out.data, v->out.width, v->out.height, v->out.stride, alpha) == 0)
        log_msg(s, "wrote %s (%dx%d)", path, v->out.width, v->out.height);
    v->png_dirty = false;
    v->last_png_ms = now_ms();
}

static void composite_view(struct view *v) {
    struct server *s = v->server;
    /* While a frame is in flight the request stays pending, and view_ack() retries
     * it; dropping it would strand frame callbacks committed without damage, and a
     * client waiting on them never draws again. */
    if (v->awaiting_ack)
        return;
    v->needs_composite = false;
    if (!v->mapped || !v->xdg || !v->xdg->surface)
        return;
    struct surface *root = v->xdg->surface;
    struct box g = v->xdg->geometry;
    if (g.w <= 0 || g.h <= 0)
        return;
    /* The view renders at its root surface's scale; GTK uses the output's. */
    const int32_t scale = root->scale > 0 ? root->scale : 1;
    if (v->out.width != g.w * scale || v->out.height != g.h * scale) {
        if (!out_ensure(v, g.w * scale, g.h * scale))
            return;
        v->damage = FULL_DAMAGE;
    }

    struct box logical = box_intersect(v->damage, (struct box) {0, 0, g.w, g.h});
    v->damage = (struct box) {0};
    surface_for_each(root, 0, 0, collect_callbacks, v);
    if (box_empty(logical)) {
        /* Nothing new to show: answer the callbacks on the next tick to pace the client. */
        wl_list_insert_list(s->orphan_callbacks.prev, &v->presented_callbacks);
        wl_list_init(&v->presented_callbacks);
        return;
    }
    struct box damage = {logical.x * scale, logical.y * scale, logical.w * scale, logical.h * scale};

    for (int32_t row = damage.y; row < damage.y + damage.h; row++)
        memset((uint8_t *) v->out.data + (size_t) row * v->out.stride + (size_t) damage.x * 4, 0, (size_t) damage.w * 4);
    struct blit_ctx ctx = {.view = v, .clip = damage, .scale = scale, .first = !view_has_below_children(root)};
    surface_for_each(root, -g.x, -g.y, blit_surface, &ctx);

    v->frame_seq++;
    if (s->headless) {
        v->png_dirty = s->png_dir != NULL;
        wl_list_insert_list(s->orphan_callbacks.prev, &v->presented_callbacks);
        wl_list_init(&v->presented_callbacks);
        return;
    }
    struct shm_buffer *rb = root->buffer ? shm_buffer_from_resource(root->buffer) : NULL;
    bool opaque = rb && !shm_buffer_has_alpha(rb) && !view_has_below_children(root);
    bridge_send(s, "frame %u %u %d %d %d %s %d %d %d %d %d %d\n", v->id, v->frame_seq,
                v->out.width, v->out.height, v->out.stride, strrchr(v->out.path, '/') + 1,
                opaque, damage.x, damage.y, damage.w, damage.h, scale);
    v->awaiting_ack = true;
    v->frame_sent_ms = now_ms();
}

void composite_all(void *data) {
    struct server *s = data;
    s->composite_idle = NULL;
    struct view *v, *tmp;
    wl_list_for_each_safe(v, tmp, &s->views, link)
        if (v->needs_composite)
            composite_view(v);
}

void view_flush_callbacks(struct view *v) {
    surface_send_frame_done(&v->presented_callbacks, now_ms());
    if (v->png_dirty && now_ms() - v->last_png_ms >= 400)
        view_write_png(v);
}

void view_ack(struct view *v, uint32_t seq) {
    if (!v->awaiting_ack || seq != v->frame_seq)
        return;
    v->awaiting_ack = false;
    surface_send_frame_done(&v->presented_callbacks, now_ms());
    if (!box_empty(v->damage) || v->needs_composite)
        view_schedule(v);
}

/* The host acks on its next display refresh, so a silent second means the ack was
 * lost (or the host dropped the frame). Without this the view would never draw
 * again: its client waits for frame callbacks that only the ack releases. */
#define ACK_TIMEOUT_MS 1500

void view_check_ack(struct view *v) {
    if (!v->awaiting_ack || now_ms() - v->frame_sent_ms < ACK_TIMEOUT_MS)
        return;
    log_msg(v->server, "view %u: no ack for frame %u, resending", v->id, v->frame_seq);
    view_ack(v, v->frame_seq);
    view_damage(v, FULL_DAMAGE);
}

void view_notify_title(struct view *v) {
    if (!v->announced) return;
    char *title = bridge_escape(v->title ? v->title : "");
    char *app_id = bridge_escape(v->app_id ? v->app_id : "");
    bridge_send(v->server, "title %u %s %s\n", v->id, title, app_id);
    free(title);
    free(app_id);
}

void view_announce(struct view *v) {
    struct server *s = v->server;
    v->announced = true;
    struct view *parent = v->parent;
    if (v->kind == VIEW_POPUP)
        bridge_send(s, "popup %u %u %d %d %d\n", v->id, parent ? parent->id : 0,
                    v->popup_x, v->popup_y, v->grabbing);
    else
        bridge_send(s, "toplevel %u %u %d %d %d %d\n", v->id, parent ? parent->id : 0,
                    v->min_w, v->min_h, v->max_w, v->max_h);
    view_notify_title(v);
    log_msg(s, "map %s %u '%s' %s", v->kind == VIEW_POPUP ? "popup" : "toplevel", v->id,
            v->title ? v->title : "", v->app_id ? v->app_id : "");
}

void view_unmap(struct view *v) {
    struct server *s = v->server;
    v->mapped = false;
    if (v->announced)
        bridge_send(s, "unmap %u\n", v->id);
    v->announced = false;
    v->awaiting_ack = false;
    v->png_dirty = false;
    surface_send_frame_done(&v->presented_callbacks, now_ms());
    out_release(&v->out);
    if (s->pointer_view == v)
        s->pointer_view = NULL;
    if (s->focused_view == v)
        s->focused_view = NULL;
}

void view_destroy(struct view *v) {
    view_unmap(v);
    struct wl_resource *cb, *tmp;
    wl_resource_for_each_safe(cb, tmp, &v->presented_callbacks)
        wl_resource_destroy(cb);
    wl_list_remove(&v->link);
    free(v->title);
    free(v->app_id);
    free(v);
}
